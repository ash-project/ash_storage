defmodule AshStorage.BlobIO.Serving do
  @moduledoc false
  # BlobIO serving phase: URL-facing strategy selection (no byte IO). Resolves to
  # {:service_url, url} | {:proxy_url, url} | :not_servable. Intentionally softer
  # than the operational phases — URL calculations collapse to nil rather than
  # surfacing {:error, reason}.

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.Layers
  alias AshStorage.BlobIO.Operation.ServiceState
  alias AshStorage.BlobIO.Support
  alias AshStorage.Token

  @proxy_url_opts [:expires_in, :disposition, :filename]

  defmodule Operation do
    @moduledoc """
    Phase-local state passed through serving layers.

    Layers may adjust `key`, `call_opts`, `service.opts`, or set `strategy`
    directly. `service.context` is rebuilt after layers run so storage services
    see the final service options.
    """

    defstruct [
      :blob_context,
      :blob,
      :key,
      :service,
      :strategy,
      layer_metadata: [],
      layers: [],
      call_opts: []
    ]

    @typedoc "Mutable operation payload for serving-strategy selection."
    @type t :: %__MODULE__{
            blob_context: BlobContext.t(),
            blob: struct(),
            key: String.t(),
            service: ServiceState.t(),
            strategy: term(),
            layer_metadata: [map()],
            layers: [AshStorage.Layer.spec()],
            call_opts: keyword()
          }
  end

  @doc """
  Return the serving strategy for a blob.

  Layers run before the default strategy is chosen. A layer can set
  `operation.strategy` to bypass the default service/proxy selection, or it can
  adjust operation options and let the default strategy evaluate them.
  """
  def strategy(nil, %BlobContext{}, _opts), do: :not_servable

  def strategy(blob, %BlobContext{} = bctx, opts) when is_list(opts) do
    bctx = BlobContext.put_blob(bctx, blob)
    layer_metadata = Support.layer_metadata_from_blob(blob)
    {service_mod, service_opts} = service_for_serving(blob, bctx, opts)

    operation =
      %Operation{
        blob_context: bctx,
        blob: blob,
        key: blob.key,
        call_opts: opts,
        service: ServiceState.new(service_mod, service_opts),
        layer_metadata: layer_metadata,
        layers: Support.layers_for(bctx, opts)
      }
      |> maybe_put_service_context()

    case Layers.run(operation, :serving) do
      {:ok, operation} ->
        operation = maybe_put_service_context(operation)

        case operation.strategy || default_strategy(operation) do
          {:service_url, url} -> {:service_url, url}
          {:proxy_url, url} -> {:proxy_url, url}
          _other -> :not_servable
        end

      {:error, _reason} ->
        :not_servable
    end
  end

  @doc """
  Return a URL for a servable blob, or `nil`.

  Previous URL calculations were mixed: generic attachment URLs collapsed
  unresolved parents/services to nil, while some typed calculations hard-matched
  service lookup. BlobIO keeps the URL surface consistently soft; read, write,
  and direct-upload operations still return richer errors.
  """
  def url(blob, %BlobContext{} = bctx, opts) when is_list(opts) do
    case strategy(blob, bctx, opts) do
      {:service_url, url} -> url
      {:proxy_url, url} -> url
      _other -> nil
    end
  end

  # Pick the built-in strategy after layers have had a chance to alter the
  # operation. Unknown modes intentionally collapse to `:not_servable`.
  defp default_strategy(%Operation{} = operation) do
    case serving_mode(operation.call_opts) do
      :service_url -> service_url_strategy(operation)
      :proxy -> proxy_url_strategy(operation)
      _other -> :not_servable
    end
  end

  # Adapter-backed URLs require a resolved service. Missing service config is
  # not an operational failure in the serving phase; it means no URL.
  defp service_url_strategy(%Operation{service: %ServiceState{mod: nil}}), do: :not_servable

  defp service_url_strategy(%Operation{} = operation) do
    {:service_url, operation.service.mod.url(operation.key, operation.service.context)}
  end

  # Proxy URLs are pure app URLs. They can be used even when the underlying
  # service cannot provide a public URL, as long as a base URL is configured.
  defp proxy_url_strategy(%Operation{} = operation) do
    case Keyword.fetch(operation.call_opts, :proxy_base_url) do
      {:ok, base_url} when is_binary(base_url) ->
        url =
          base_url
          |> proxy_url(operation.key)
          |> maybe_sign_proxy_url(operation.key, operation.call_opts)

        {:proxy_url, url}

      :error ->
        :not_servable
    end
  end

  defp maybe_put_service_context(%Operation{service: %ServiceState{mod: nil}} = operation),
    do: operation

  defp maybe_put_service_context(%Operation{} = operation),
    do: Support.put_service_context(operation)

  # Serving must derive the same object key as reading, so a persisted blob's
  # stored service options (e.g. a pinned prefix) take precedence over runtime
  # resolution — otherwise serve and read can compute different keys for the same
  # blob. An explicit `:service` override still wins; a blob with no persisted
  # service name falls back to the forgiving runtime resolution (key-only or
  # unsaved contexts).
  defp service_for_serving(blob, bctx, opts) do
    case Keyword.fetch(opts, :service) do
      {:ok, {service_mod, service_opts}} -> {service_mod, service_opts}
      :error -> service_from_blob(blob, bctx, opts)
    end
  end

  defp service_from_blob(%{service_name: service_name} = blob, _bctx, _opts)
       when not is_nil(service_name) do
    blob = Ash.load!(blob, :parsed_service_opts)
    {service_name, blob.parsed_service_opts || []}
  end

  defp service_from_blob(_blob, bctx, opts), do: Support.service_for_operation(bctx, opts)

  defp serving_mode(opts),
    do: Keyword.get(opts, :serve, Keyword.get(opts, :strategy, :service_url))

  defp proxy_url(base_url, key) do
    base_url = String.trim_trailing(base_url, "/")
    key = String.trim_leading(key, "/")

    "#{base_url}/#{key}"
  end

  defp maybe_sign_proxy_url(url, key, opts) do
    case proxy_secret(opts) do
      nil -> url
      secret -> Token.signed_url(url, secret, key, Keyword.take(opts, @proxy_url_opts))
    end
  end

  defp proxy_secret(opts) do
    Keyword.get(opts, :proxy_secret) ||
      Keyword.get(opts, :secret) ||
      proxy_access_secret(Keyword.get(opts, :access))
  end

  defp proxy_access_secret({:signed, signed_opts}) when is_list(signed_opts),
    do: Keyword.get(signed_opts, :secret)

  defp proxy_access_secret({:signed, secret}) when is_binary(secret), do: secret

  defp proxy_access_secret(_access), do: nil
end
