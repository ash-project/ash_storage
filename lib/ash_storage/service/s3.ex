if Code.ensure_loaded?(ReqS3) do
  defmodule AshStorage.Service.S3 do
    @moduledoc """
    A storage service for Amazon S3 and S3-compatible services.

    Uses `req` with `req_s3` for HTTP operations and presigned URLs.

    ## Configuration

        storage do
          service {AshStorage.Service.S3,
            bucket: "my-bucket",
            region: "us-east-1",
            access_key_id_env: "MY_APP_AWS_ACCESS_KEY_ID",
            secret_access_key_env: "MY_APP_AWS_SECRET_ACCESS_KEY"}
        end

    Prefer `:access_key_id_env` / `:secret_access_key_env` over literal
    secrets. Raw `:access_key_id` and `:secret_access_key` values are accepted
    for immediate service calls, but are intentionally not persisted on blob
    records. Use env-backed credentials for attachment flows that later operate
    from stored blob records, such as purge, analysis, and variants.

    ## Options

    - `:bucket` - (required) the S3 bucket name
    - `:region` - AWS region (default: `"us-east-1"`)
    - `:access_key_id` - AWS access key ID. Falls back to the environment
      variable named by `:access_key_id_env`. Not persisted on blob records;
      use `:access_key_id_env` for purge/analysis/variants
    - `:access_key_id_env` - environment variable to read the access key ID
      from (default: `"AWS_ACCESS_KEY_ID"`)
    - `:secret_access_key` - AWS secret access key. Falls back to the
      environment variable named by `:secret_access_key_env`. Not persisted on
      blob records; use `:secret_access_key_env` for purge/analysis/variants
    - `:secret_access_key_env` - environment variable to read the secret
      access key from (default: `"AWS_SECRET_ACCESS_KEY"`)
    - `:endpoint_url` - custom endpoint URL for S3-compatible services (e.g. MinIO, Tigris)
    - `:prefix` - optional key prefix (e.g. `"uploads/"`)
    - `:decode_body` - opt back into Req's content-type response decoding on
      `download/2`. Defaults to `false`; see the `AshStorage.Service`
      `download/2` callback docs for the raw-bytes contract.

    ## Static credentials without environment variables

    Credentials are never persisted on blob records, so an operation that
    starts from a record — purge, analysis, variants — resolves them from the
    environment variables the record names. If static credentials must stay
    out of the environment altogether, wrap this service in a small module of
    your own that merges them in from your application's configuration on
    every call, and configure that module as the service:

        defmodule MyApp.S3 do
          @behaviour AshStorage.Service
          alias AshStorage.Service.S3

          defdelegate service_opts_fields, to: S3

          def upload(key, data, ctx), do: S3.upload(key, data, with_credentials(ctx))
          def download(key, ctx), do: S3.download(key, with_credentials(ctx))
          def delete(key, ctx), do: S3.delete(key, with_credentials(ctx))
          def exists?(key, ctx), do: S3.exists?(key, with_credentials(ctx))
          def head(key, ctx), do: S3.head(key, with_credentials(ctx))
          def url(key, ctx), do: S3.url(key, with_credentials(ctx))
          def direct_upload(key, ctx), do: S3.direct_upload(key, with_credentials(ctx))

          defp with_credentials(ctx) do
            credentials = Application.fetch_env!(:my_app, :s3_credentials)
            %{ctx | service_opts: Keyword.merge(ctx.service_opts, credentials)}
          end
        end

    Blob records then persist `MyApp.S3` as the service, with the same
    credential-free options, and every call — including one that starts from
    a record — gets the credentials merged in at call time.
    """

    @behaviour AshStorage.Service

    @default_access_key_id_env "AWS_ACCESS_KEY_ID"
    @default_secret_access_key_env "AWS_SECRET_ACCESS_KEY"

    # Persisted on the blob row: the connection shape and the *names* of the
    # credential environment variables, never the credentials themselves.
    @impl true
    def service_opts_fields do
      [
        bucket: [type: :string, allow_nil?: false],
        region: [type: :string],
        access_key_id_env: [type: :string],
        secret_access_key_env: [type: :string],
        endpoint_url: [type: :string],
        prefix: [type: :string],
        decode_body: [type: :boolean]
      ]
    end

    @impl true
    def upload(key, data, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)
      # Single-PUT only. Multipart uploads need per-part Content-MD5 and a
      # different completion check; see documentation/topics/checksum-verification.md.
      put_opts =
        [url: "/#{full_key}", body: data]
        |> maybe_put_content_md5(ctx, data)
        |> maybe_put_content_type(ctx)

      with {:ok, request} <- req(ctx) do
        case Req.put(request, put_opts) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, %{status: status, body: body}} -> {:error, {status, body}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def download(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      decode_body? = Keyword.get(ctx.service_opts, :decode_body, false)

      with {:ok, request} <- req(ctx),
           {:ok, %{status: 200, body: body}} <-
             Req.get(request, url: "/#{full_key}", decode_body: decode_body?),
           :ok <- verify_md5(body, ctx.expected_md5) do
        {:ok, body}
      else
        {:ok, %{status: 404}} -> {:error, :not_found}
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def delete(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      with {:ok, request} <- req(ctx) do
        case Req.delete(request, url: "/#{full_key}") do
          {:ok, %{status: status}} when status in [200, 204] -> :ok
          {:ok, %{status: 404}} -> :ok
          {:ok, %{status: status, body: body}} -> {:error, {status, body}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def exists?(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      with {:ok, request} <- req(ctx) do
        case Req.head(request, url: "/#{full_key}") do
          {:ok, %{status: 200}} -> {:ok, true}
          {:ok, %{status: 404}} -> {:ok, false}
          {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def head(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      with {:ok, request} <- req(ctx) do
        case Req.head(request, url: "/#{full_key}") do
          {:ok, %{status: 200, headers: headers}} ->
            etag = headers |> header(["etag"]) |> unquote_etag()

            {:ok,
             %{
               etag: etag,
               content_md5: etag_to_md5(etag),
               byte_size: parse_int(header(headers, ["content-length"]))
             }}

          {:ok, %{status: 404}} ->
            {:error, :not_found}

          {:ok, %{status: status, body: body}} ->
            {:error, {status, body}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    @impl true
    def url(key, %AshStorage.Service.Context{} = ctx) do
      opts = ctx.service_opts
      full_key = prefixed_key(key, ctx)

      if Keyword.get(opts, :presigned, false) do
        case resolve_credentials(opts) do
          {:ok, {access_key_id, secret_access_key}} ->
            presign_opts =
              [
                bucket: Keyword.fetch!(opts, :bucket),
                key: full_key,
                region: Keyword.get(opts, :region, "us-east-1"),
                access_key_id: access_key_id,
                secret_access_key: secret_access_key
              ]
              |> maybe_put(:endpoint_url, Keyword.get(opts, :endpoint_url))
              |> maybe_put(:expires, Keyword.get(opts, :expires_in))

            ReqS3.presign_url(presign_opts)

          {:error, reason} ->
            raise ArgumentError, "could not generate S3 presigned URL: #{inspect(reason)}"
        end
      else
        bucket = Keyword.fetch!(opts, :bucket)
        endpoint = endpoint_url(opts)
        "#{endpoint}/#{bucket}/#{full_key}"
      end
    end

    @doc """
    Generate a presigned URL or form for direct client-side upload.

    By default, generates a presigned PUT URL (`:method` option defaults to `:put`).
    Set `method: :post` in service_opts to use presigned POST forms instead.

    For `:put`, returns `%{url: presigned_url, method: :put}`.
    For `:post`, returns `%{url: form_url, method: :post, fields: [...]}`.

    Note: this currently returns no `:headers`. If you add request headers that
    SigV4 signs (any `x-amz-*` header, e.g. SSE or `x-amz-meta-*`), they must be
    included at presign time — clients sending them post-hoc will get a signature
    mismatch.
    """
    @impl true
    def direct_upload(key, %AshStorage.Service.Context{} = ctx) do
      opts = ctx.service_opts
      full_key = prefixed_key(key, ctx)
      method = Keyword.get(opts, :direct_upload_method, :put)

      with {:ok, {access_key_id, secret_access_key}} <- resolve_credentials(opts) do
        presign_base =
          [
            bucket: Keyword.fetch!(opts, :bucket),
            key: full_key,
            region: Keyword.get(opts, :region, "us-east-1"),
            access_key_id: access_key_id,
            secret_access_key: secret_access_key
          ]
          |> maybe_put(:endpoint_url, Keyword.get(opts, :endpoint_url))

        case method do
          :put ->
            url = ReqS3.presign_url(Keyword.put(presign_base, :method, :put))
            {:ok, %{url: url, method: :put}}

          :post ->
            presign_opts =
              presign_base
              |> maybe_put(:content_type, Keyword.get(opts, :content_type))
              |> maybe_put(:max_size, Keyword.get(opts, :max_size))

            form = ReqS3.presign_form(presign_opts)
            {:ok, %{url: form.url, method: :post, fields: form.fields}}
        end
      end
    end

    # -- Private helpers --

    defp req(%AshStorage.Service.Context{} = ctx) do
      opts = ctx.service_opts

      with {:ok, {access_key_id, secret_access_key}} <- resolve_credentials(opts) do
        bucket = Keyword.fetch!(opts, :bucket)
        endpoint = endpoint_url(opts)

        sigv4_opts = [
          service: :s3,
          region: Keyword.get(opts, :region, "us-east-1"),
          access_key_id: access_key_id,
          secret_access_key: secret_access_key
        ]

        tls_versions =
          Keyword.get(opts, :tls_versions, "tlsv1.2")
          |> String.split(",")
          |> Enum.reject(&(String.trim(&1) not in ["tlsv1.2", "tlsv1.3"]))
          |> Enum.map(&String.to_atom(String.trim(&1)))

        transport_opts =
          [transport_opts: [versions: tls_versions]]

        {:ok,
         Req.new(
           base_url: "#{endpoint}/#{bucket}",
           aws_sigv4: sigv4_opts,
           retry: :transient,
           connect_options: transport_opts
         )}
      end
    end

    defp endpoint_url(opts) do
      Keyword.get(opts, :endpoint_url) ||
        "https://s3.#{Keyword.get(opts, :region, "us-east-1")}.amazonaws.com"
    end

    defp prefixed_key(key, %AshStorage.Service.Context{} = ctx) do
      case Keyword.get(ctx.service_opts, :prefix) do
        nil -> key
        "" -> key
        prefix -> "#{prefix}#{key}"
      end
    end

    # As `AshStorage.Service.AzureBlob` does it: a raw value in the options wins
    # for this call; otherwise the environment variable the options name, or
    # the AWS default. Only the variable names are persisted on blob rows, so
    # an operation that starts from a row resolves exactly like this one.
    defp resolve_credentials(opts) do
      with {:ok, access_key_id} <-
             resolve_credential(
               opts,
               :access_key_id,
               :access_key_id_env,
               @default_access_key_id_env
             ),
           {:ok, secret_access_key} <-
             resolve_credential(
               opts,
               :secret_access_key,
               :secret_access_key_env,
               @default_secret_access_key_env
             ) do
        {:ok, {access_key_id, secret_access_key}}
      end
    end

    defp resolve_credential(opts, key, env_key, default_env) do
      case Keyword.get(opts, key) || System.get_env(Keyword.get(opts, env_key) || default_env) do
        nil -> {:error, :missing_credentials}
        "" -> {:error, :missing_credentials}
        value -> {:ok, value}
      end
    end

    defp maybe_put(keyword, _key, nil), do: keyword
    defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

    # Only set Content-MD5 when the body is an in-memory binary or iodata,
    # since the header must hash the exact bytes that go on the wire.
    defp maybe_put_content_md5(put_opts, %{expected_md5: md5}, data)
         when is_binary(md5) and (is_binary(data) or is_list(data)) do
      Keyword.put(put_opts, :headers, [{"content-md5", md5}])
    end

    defp maybe_put_content_md5(put_opts, _ctx, _data), do: put_opts

    # Forward the blob's Content-Type so the stored object reports the
    # right MIME type. Without this S3 records `binary/octet-stream` on
    # every object (the SigV4 default for PUTs with no `Content-Type`
    # header), which makes browsers refuse to render the response as the
    # type the caller intended — most visibly, `<img src>` requests hit
    # Opaque Response Blocking and fail silently.
    #
    # We only set the header when the context actually carries a value,
    # so callers who never set `:content_type` keep the old behaviour.
    defp maybe_put_content_type(put_opts, %{content_type: ct})
         when is_binary(ct) and ct != "" do
      existing = Keyword.get(put_opts, :headers, [])
      Keyword.put(put_opts, :headers, [{"content-type", ct} | existing])
    end

    defp maybe_put_content_type(put_opts, _ctx), do: put_opts

    defp verify_md5(_data, nil), do: :ok

    defp verify_md5(data, expected) do
      if Base.encode64(:erlang.md5(data)) == expected,
        do: :ok,
        else: {:error, :checksum_mismatch}
    end

    defp header(headers, names) do
      Enum.find_value(names, fn name ->
        case Map.get(headers, name) do
          [value | _] -> value
          _ -> nil
        end
      end)
    end

    defp unquote_etag(nil), do: nil
    defp unquote_etag(etag), do: String.trim(etag, "\"")

    # S3 single-PUT ETag is the lowercase 32-hex MD5; multipart ETag has a
    # `-N` suffix and is NOT the body MD5. Re-encode hex as base64 so the
    # value is comparable to `:erlang.md5/1 |> Base.encode64/1`.
    defp etag_to_md5(nil), do: nil

    defp etag_to_md5(etag) do
      case Base.decode16(etag, case: :lower) do
        {:ok, raw} when byte_size(raw) == 16 -> Base.encode64(raw)
        _ -> nil
      end
    end

    defp parse_int(nil), do: nil

    defp parse_int(value) do
      case Integer.parse(value) do
        {n, _} -> n
        :error -> nil
      end
    end
  end
end
