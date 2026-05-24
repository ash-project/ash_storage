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
            access_key_id: "AKIA...",
            secret_access_key: "..."}
        end

    ## Options

    - `:bucket` - (required) the S3 bucket name
    - `:region` - AWS region (default: `"us-east-1"`)
    - `:access_key_id` - AWS access key ID (falls back to `AWS_ACCESS_KEY_ID` env var)
    - `:secret_access_key` - AWS secret access key (falls back to `AWS_SECRET_ACCESS_KEY` env var)
    - `:endpoint_url` - custom endpoint URL for S3-compatible services (e.g. MinIO, Tigris)
    - `:prefix` - optional key prefix (e.g. `"uploads/"`)
    - `:decode_body` - whether `download/2` runs Req's content-type response
      decoding (JSON → map, CSV → rows, gzip → unzipped, etc.). Defaults to
      `true` to match Req's own default; pass `false` when you need the raw
      uploaded bytes.
    """

    @behaviour AshStorage.Service

    @impl true
    def service_opts_fields do
      [
        bucket: [type: :string, allow_nil?: false],
        region: [type: :string],
        access_key_id: [type: :string],
        secret_access_key: [type: :string],
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

      case Req.put(req(ctx), put_opts) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def download(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      decode_body? = Keyword.get(ctx.service_opts, :decode_body, true)

      with {:ok, %{status: 200, body: body}} <-
             Req.get(req(ctx), url: "/#{full_key}", decode_body: decode_body?),
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

      case Req.delete(req(ctx), url: "/#{full_key}") do
        {:ok, %{status: status}} when status in [200, 204] -> :ok
        {:ok, %{status: 404}} -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {status, body}}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def exists?(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      case Req.head(req(ctx), url: "/#{full_key}") do
        {:ok, %{status: 200}} -> {:ok, true}
        {:ok, %{status: 404}} -> {:ok, false}
        {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def head(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      case Req.head(req(ctx), url: "/#{full_key}") do
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

    @impl true
    def url(key, %AshStorage.Service.Context{} = ctx) do
      opts = ctx.service_opts
      full_key = prefixed_key(key, ctx)

      if Keyword.get(opts, :presigned, false) do
        presign_opts =
          [
            bucket: Keyword.fetch!(opts, :bucket),
            key: full_key,
            region: Keyword.get(opts, :region, "us-east-1")
          ]
          |> maybe_put(
            :access_key_id,
            resolve_credential(opts, :access_key_id, "AWS_ACCESS_KEY_ID")
          )
          |> maybe_put(
            :secret_access_key,
            resolve_credential(opts, :secret_access_key, "AWS_SECRET_ACCESS_KEY")
          )
          |> maybe_put(:endpoint_url, Keyword.get(opts, :endpoint_url))
          |> maybe_put(:expires, Keyword.get(opts, :expires_in))

        ReqS3.presign_url(presign_opts)
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

      presign_base =
        [
          bucket: Keyword.fetch!(opts, :bucket),
          key: full_key,
          region: Keyword.get(opts, :region, "us-east-1")
        ]
        |> maybe_put(
          :access_key_id,
          resolve_credential(opts, :access_key_id, "AWS_ACCESS_KEY_ID")
        )
        |> maybe_put(
          :secret_access_key,
          resolve_credential(opts, :secret_access_key, "AWS_SECRET_ACCESS_KEY")
        )
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

    # -- Private helpers --

    defp req(%AshStorage.Service.Context{} = ctx) do
      opts = ctx.service_opts
      bucket = Keyword.fetch!(opts, :bucket)
      endpoint = endpoint_url(opts)

      sigv4_opts =
        [service: :s3, region: Keyword.get(opts, :region, "us-east-1")]
        |> maybe_put(
          :access_key_id,
          resolve_credential(opts, :access_key_id, "AWS_ACCESS_KEY_ID")
        )
        |> maybe_put(
          :secret_access_key,
          resolve_credential(opts, :secret_access_key, "AWS_SECRET_ACCESS_KEY")
        )

      Req.new(
        base_url: "#{endpoint}/#{bucket}",
        aws_sigv4: sigv4_opts,
        retry: :transient
      )
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

    defp resolve_credential(opts, key, env_var) do
      Keyword.get(opts, key) || System.get_env(env_var)
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
