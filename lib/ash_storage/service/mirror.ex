defmodule AshStorage.Service.Mirror do
  @moduledoc """
  A composite storage service that fans uploads and deletes out to a list of
  child services for redundancy.

  ## Configuration

      storage do
        service {AshStorage.Service.Mirror,
          services: [
            {AshStorage.Service.S3, bucket: "primary"},
            {AshStorage.Service.S3, bucket: "backup", region: "eu-west-1"}
          ]}
      end

  The first child is the *primary*. All write operations fan out to every
  child sequentially in declaration order; reads, `url/2`, and `direct_upload/2`
  go through the primary (with read-time fall-through to secondaries on
  `:not_found`).

  ## Semantics

  | Operation         | Behaviour                                                   |
  |-------------------|-------------------------------------------------------------|
  | `upload/3`        | Each child in order. First error halts and propagates.      |
  | `delete/2`        | Each child in order. First error halts and propagates.      |
  | `download/2`      | Primary first; on `:not_found` fall through to secondaries. |
  | `exists?/2`       | Primary first; same fall-through as `download/2`.           |
  | `url/2`           | Primary only.                                               |
  | `direct_upload/2` | Primary only.                                               |

  Non-`:not_found` read errors are not swallowed — they propagate immediately.

  ## Partial-failure cleanup

  If `upload/3` fails on a non-first child, the bytes written to earlier
  children are **not** cleaned up. The strict fail-fast model keeps the runtime
  semantics simple; orphan cleanup (a separate roadmap item) is responsible for
  reaping leftovers.

  ## Runtime-config requirement

  Mirror is configured at runtime via the resource's `storage` DSL or app
  config. The blob row stores `service_name: AshStorage.Service.Mirror` with an
  empty `service_opts` map — the child services are *not* persisted. This
  means:

  - Synchronous attach/upload/url/download/delete work normally — the live
    config is in scope.
  - Async paths that rebuild a context purely from `blob.parsed_service_opts`
    (e.g. AshOban purge jobs) will get a clear error. Such jobs need to
    re-resolve the Mirror config from app config before invoking the service.

  ## Limitations

  - Wrapping services that return `{:ok, extra_blob_attrs}` from `upload/3`
    (e.g. an encryption layer) are not supported beyond the primary. Only the
    primary's extra attrs are written to the blob row; if a secondary returns
    a differing map a `Logger.warning/1` is emitted.

  ## Options

  - `:services` - (required) ordered list of `{module, opts}` tuples; the first
    is treated as the primary.

  ## `:mirrors` sugar

  As a shorthand, you can decorate any service tuple with a `:mirrors` option
  and it will be expanded into a Mirror automatically:

      service {AshStorage.Service.S3, [bucket: "primary", mirrors: [
        {AshStorage.Service.S3, bucket: "backup"}
      ]]}

  is equivalent to:

      service {AshStorage.Service.Mirror, services: [
        {AshStorage.Service.S3, bucket: "primary"},
        {AshStorage.Service.S3, bucket: "backup"}
      ]}

  The expansion happens once at service-resolution time
  (`AshStorage.Info.service_for_attachment/2`); the rest of the system sees a
  plain Mirror tuple. An empty or absent `:mirrors` list is a no-op.
  """

  require Logger

  @behaviour AshStorage.Service

  alias AshStorage.Service.Context

  @doc """
  Expand the `:mirrors` sugar on a `{module, opts}` service tuple.

  If `opts` includes a non-empty `:mirrors` list, returns a Mirror tuple whose
  primary is the original service (with `:mirrors` stripped) and whose
  secondaries are the listed mirrors. Otherwise returns the input tuple
  unchanged (with `:mirrors` stripped if it was present but empty).
  """
  @spec expand_sugar({module(), keyword()}) :: {module(), keyword()}
  def expand_sugar({mod, opts}) when is_atom(mod) and is_list(opts) do
    case Keyword.pop(opts, :mirrors) do
      {nil, _} ->
        {mod, opts}

      {[], remaining} ->
        {mod, remaining}

      {mirrors, remaining} when is_list(mirrors) ->
        {__MODULE__, services: [{mod, remaining} | mirrors]}
    end
  end

  def expand_sugar(other), do: other

  @impl true
  def upload(key, data, %Context{} = ctx) do
    children = children!(ctx)
    [primary | _] = children

    result =
      children
      |> Enum.reduce_while({:ok, %{}}, fn child, {:ok, primary_attrs} ->
        child_ctx = build_child_ctx(child, ctx)

        case child.module.upload(key, data, child_ctx) do
          :ok ->
            {:cont, {:ok, primary_attrs}}

          {:ok, attrs} when is_map(attrs) ->
            if child == primary do
              {:cont, {:ok, attrs}}
            else
              if attrs != primary_attrs and primary_attrs != %{} do
                Logger.warning(
                  "AshStorage.Service.Mirror: secondary #{inspect(child.module)} " <>
                    "returned extra blob attrs that differ from the primary's. " <>
                    "Only the primary's attrs are persisted."
                )
              end

              {:cont, {:ok, primary_attrs}}
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, attrs} when map_size(attrs) == 0 -> :ok
      other -> other
    end
  end

  @impl true
  def download(key, %Context{} = ctx) do
    try_in_order(children!(ctx), & &1.module.download(key, build_child_ctx(&1, ctx)))
  end

  @impl true
  def exists?(key, %Context{} = ctx) do
    try_in_order_exists(children!(ctx), & &1.module.exists?(key, build_child_ctx(&1, ctx)))
  end

  @impl true
  def delete(key, %Context{} = ctx) do
    children!(ctx)
    |> Enum.reduce_while(:ok, fn child, :ok ->
      case child.module.delete(key, build_child_ctx(child, ctx)) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @impl true
  def url(key, %Context{} = ctx) do
    primary = primary!(ctx)
    primary.module.url(key, build_child_ctx(primary, ctx))
  end

  @impl true
  def direct_upload(key, %Context{} = ctx) do
    primary = primary!(ctx)
    primary.module.direct_upload(key, build_child_ctx(primary, ctx))
  end

  # -- internal --

  defp children!(%Context{service_opts: opts}) do
    case Keyword.fetch(opts, :services) do
      {:ok, []} ->
        raise ArgumentError,
              "AshStorage.Service.Mirror requires at least one child service in :services"

      {:ok, list} ->
        Enum.map(list, fn {mod, child_opts} when is_atom(mod) and is_list(child_opts) ->
          %{module: mod, opts: child_opts}
        end)

      :error ->
        raise ArgumentError,
              "AshStorage.Service.Mirror was invoked without a :services list in service_opts. " <>
                "Mirror requires runtime configuration via the resource's `storage` DSL or app " <>
                "config; it is not persisted on the blob row. If you are running an async/Oban " <>
                "job, re-resolve the Mirror config from app config before invoking the service."
    end
  end

  defp primary!(ctx) do
    [primary | _] = children!(ctx)
    primary
  end

  defp build_child_ctx(child, %Context{} = parent) do
    %Context{
      service_opts: child.opts,
      resource: parent.resource,
      attachment: parent.attachment,
      actor: parent.actor,
      tenant: parent.tenant
    }
  end

  defp try_in_order([], _fun), do: {:error, :not_found}

  defp try_in_order([child | rest], fun) do
    case fun.(child) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> try_in_order(rest, fun)
      {:error, _} = error -> error
    end
  end

  defp try_in_order_exists([], _fun), do: {:ok, false}

  defp try_in_order_exists([child | rest], fun) do
    case fun.(child) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> try_in_order_exists(rest, fun)
      {:error, :not_found} -> try_in_order_exists(rest, fun)
      {:error, _} = error -> error
    end
  end
end
