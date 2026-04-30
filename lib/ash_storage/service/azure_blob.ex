if Code.ensure_loaded?(Req) do
  defmodule AshStorage.Service.AzureBlob do
    @moduledoc """
    A storage service for Azure Blob Storage.

    Uses `Req` and Azure Blob Storage SAS URLs for HTTP operations. The service can
    either append a configured SAS token or generate short-lived per-blob SAS tokens
    from an account key.

    ## Configuration

        storage do
          service {AshStorage.Service.AzureBlob,
            account: "myaccount",
            container: "uploads",
            account_key_env: "AZURE_STORAGE_ACCOUNT_KEY",
            presigned: true}
        end

    Prefer `:account_key_env` or `:sas_token_env` over literal secrets. Raw
    `:account_key` and `:sas_token` values are accepted for immediate service
    calls, but are intentionally not persisted on blob records. Use env-backed
    credentials for attachment flows that later operate from stored blob records,
    such as purge, analysis, and variants.

    ## Options

    - `:account` - (required) the Azure Storage account name
    - `:container` - (required) the blob container name
    - `:account_key` - base64-encoded storage account key. Falls back to the
      `AZURE_STORAGE_ACCOUNT_KEY` environment variable. Not persisted on blob
      records; use `:account_key_env` for purge/analysis/variants
    - `:account_key_env` - environment variable to read the account key from
      (default: `"AZURE_STORAGE_ACCOUNT_KEY"`)
    - `:sas_token` - pre-generated SAS token to append to requests. Falls back to
      the `AZURE_STORAGE_SAS_TOKEN` environment variable. Not persisted on blob
      records; use `:sas_token_env` for purge/analysis/variants
    - `:sas_token_env` - environment variable to read the SAS token from
      (default: `"AZURE_STORAGE_SAS_TOKEN"`)
    - `:endpoint_url` - custom endpoint URL. Useful for Azurite, e.g.
      `"http://127.0.0.1:10000/devstoreaccount1"`
    - `:prefix` - optional key prefix (e.g. `"uploads/"`)
    - `:presigned` - when `true`, `url/2` returns a read SAS URL. Otherwise it
      returns the unsigned/public blob URL
    - `:expires_in` - default SAS expiration for `url/2`, in seconds (default: `3600`)
    - `:direct_upload_expires_in` - SAS expiration for direct uploads, in seconds
      (default: `900`)
    - `:service_version` - Azure Storage service version for SAS generation
      (default: `"2020-12-06"`)
    - `:signed_protocol` - SAS protocol restriction. Defaults to `"https"`, or
      `"https,http"` for `http://` endpoints

    ## Azure setup

    Create a StorageV2 account and a private blob container. For account-key SAS
    generation, make a storage account key available to the application, preferably
    through `:account_key_env`. Alternatively, configure a pre-generated container
    or account SAS through `:sas_token_env`.

    Configured SAS tokens are reused for every operation. They must be scoped to
    the target container/account and include the permissions needed by each flow:
    read (`r`) for downloads/URLs/existence checks, create/write (`c`, `w`) for
    uploads and direct uploads, and delete (`d`) for purge/delete.

    Azure SAS URLs can be given to clients for a specific blob, which covers this
    service's read URLs and single-request direct uploads. They are not identical
    to S3 request presigning: this service does not currently support
    block-level/per-part upload signing, resumable uploads, or Azure AD/user
    delegation SAS generation.

    For browser direct uploads, configure CORS on the storage account to allow your
    application origin, the `PUT`/`OPTIONS` methods, and the request headers your
    client sends, including `x-ms-blob-type` and `content-type`.

    ## Limits

    Uploads use a single `Put Blob` request, which Azure caps at 5,000 MiB per
    request and recommends keeping under 256 MiB. Block-based uploads
    (`Put Block` / `Put Block List`) for larger or resumable uploads are tracked
    on the roadmap.

    ## Per-call Content-Type

    `:content_type` listed below is read from `service_opts` (i.e. set on the
    storage configuration), not from per-call attach or `prepare_direct_upload/3`
    options. To pin a specific Content-Type to direct uploads from a single
    attachment, configure the service for that attachment with `:content_type`
    set. Browsers performing direct uploads typically set their own
    `Content-Type` request header, so the SAS-signed override is only needed
    when you want it pinned server-side.
    """

    @behaviour AshStorage.Service

    @default_account_key_env "AZURE_STORAGE_ACCOUNT_KEY"
    @default_sas_token_env "AZURE_STORAGE_SAS_TOKEN"
    @default_service_version "2020-12-06"

    @impl true
    def service_opts_fields do
      [
        account: [type: :string, allow_nil?: false],
        container: [type: :string, allow_nil?: false],
        endpoint_url: [type: :string],
        prefix: [type: :string],
        account_key_env: [type: :string],
        sas_token_env: [type: :string],
        presigned: [type: :boolean],
        expires_in: [type: :integer],
        direct_upload_expires_in: [type: :integer],
        service_version: [type: :string],
        signed_protocol: [type: :string]
      ]
    end

    @impl true
    def upload(key, data, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      # Azure's `Put Blob` rejects Transfer-Encoding: chunked, which Req+Finch
      # emit for any non-iodata body (including File.Stream). Materialise the
      # stream so the request goes out with a fixed Content-Length.
      data = materialize_body(data)

      with {:ok, url} <- signed_blob_url(full_key, ctx, permissions: "cw", expires_in: 900) do
        headers =
          ctx
          |> base_headers()
          |> Map.put("x-ms-blob-type", "BlockBlob")
          |> maybe_put("content-type", Keyword.get(ctx.service_opts, :content_type))

        case Req.put(url, body: data, headers: headers) do
          {:ok, %{status: status}} when status in 200..299 -> :ok
          {:ok, %{status: status, body: body}} -> {:error, {status, body}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def download(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      with {:ok, url} <- signed_blob_url(full_key, ctx, permissions: "r", expires_in: 900) do
        case Req.get(url, headers: base_headers(ctx)) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: 404}} -> {:error, :not_found}
          {:ok, %{status: status, body: body}} -> {:error, {status, body}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def delete(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      with {:ok, url} <- signed_blob_url(full_key, ctx, permissions: "d", expires_in: 900) do
        case Req.delete(url, headers: base_headers(ctx)) do
          {:ok, %{status: status}} when status in [200, 202, 204] -> :ok
          {:ok, %{status: 404}} -> :ok
          {:ok, %{status: status, body: body}} -> {:error, {status, body}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def exists?(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      with {:ok, url} <- signed_blob_url(full_key, ctx, permissions: "r", expires_in: 900) do
        case Req.head(url, headers: base_headers(ctx)) do
          {:ok, %{status: 200}} -> {:ok, true}
          {:ok, %{status: 404}} -> {:ok, false}
          {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    @impl true
    def url(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      if Keyword.get(ctx.service_opts, :presigned, false) do
        case signed_blob_url(full_key, ctx,
               permissions: "r",
               expires_in: Keyword.get(ctx.service_opts, :expires_in, 3600),
               response_headers: response_headers(ctx.service_opts)
             ) do
          {:ok, url} ->
            url

          {:error, reason} ->
            raise ArgumentError, "could not generate Azure Blob SAS URL: #{inspect(reason)}"
        end
      else
        blob_url(full_key, ctx)
      end
    end

    @doc """
    Generate a SAS-signed PUT URL for direct client-side upload.

    Azure Blob Storage direct uploads require the `x-ms-blob-type: BlockBlob`
    header. The returned map includes this header.
    """
    @impl true
    def direct_upload(key, %AshStorage.Service.Context{} = ctx) do
      full_key = prefixed_key(key, ctx)

      with {:ok, url} <-
             signed_blob_url(full_key, ctx,
               permissions: "cw",
               expires_in: Keyword.get(ctx.service_opts, :direct_upload_expires_in, 900)
             ) do
        headers =
          %{"x-ms-blob-type" => "BlockBlob"}
          |> maybe_put("content-type", Keyword.get(ctx.service_opts, :content_type))

        {:ok, %{url: url, method: :put, headers: headers}}
      end
    end

    # -- Private helpers --

    defp materialize_body(%File.Stream{path: path}), do: File.read!(path)
    defp materialize_body(data) when is_binary(data) or is_list(data), do: data

    defp signed_blob_url(key, %AshStorage.Service.Context{} = ctx, opts) do
      base_url = blob_url(key, ctx)

      case resolve_sas_token(ctx.service_opts) do
        {:ok, token} ->
          with :ok <- check_sas_permissions(token, Keyword.get(opts, :permissions)) do
            {:ok, append_query(base_url, token)}
          end

        :error ->
          case generate_sas_query(key, ctx, opts) do
            {:ok, query} -> {:ok, append_query(base_url, query)}
            {:error, reason} -> {:error, reason}
          end
      end
    end

    # A configured SAS token is reused for every operation, so it must already
    # grant the permissions each operation needs. Parse the `sp` field and fail
    # fast when a required permission is missing. When the token has no `sp`
    # parameter, fall through and let Azure return its own error.
    defp check_sas_permissions(_token, nil), do: :ok
    defp check_sas_permissions(_token, ""), do: :ok

    defp check_sas_permissions(token, required) do
      case sas_granted_permissions(token) do
        {:ok, granted} ->
          missing =
            required
            |> String.graphemes()
            |> Enum.uniq()
            |> Enum.reject(&String.contains?(granted, &1))

          case missing do
            [] ->
              :ok

            _ ->
              {:error,
               {:sas_missing_permissions,
                required: required, granted: granted, missing: Enum.join(missing)}}
          end

        :error ->
          :ok
      end
    end

    defp sas_granted_permissions(token) do
      case token |> URI.decode_query() |> Map.get("sp") do
        nil -> :error
        "" -> :error
        sp -> {:ok, sp}
      end
    end

    defp generate_sas_query(key, %AshStorage.Service.Context{} = ctx, opts) do
      service_opts = ctx.service_opts
      account = Keyword.fetch!(service_opts, :account)
      container = Keyword.fetch!(service_opts, :container)

      with {:ok, account_key} <- resolve_account_key(service_opts) do
        permissions = Keyword.fetch!(opts, :permissions)
        version = service_version(service_opts)
        resource = Keyword.get(opts, :resource, "b")
        start_time = opts |> Keyword.get(:starts_at) |> format_time()
        expiry_time = opts |> expiry_time(service_opts) |> format_time()
        protocol = signed_protocol(service_opts)
        response_headers = Keyword.get(opts, :response_headers, %{})
        canonicalized_resource = "/blob/#{account}/#{container}/#{key}"

        string_to_sign =
          [
            permissions,
            start_time,
            expiry_time,
            canonicalized_resource,
            "",
            "",
            protocol,
            version,
            resource,
            "",
            "",
            Map.get(response_headers, "rscc", ""),
            Map.get(response_headers, "rscd", ""),
            Map.get(response_headers, "rsce", ""),
            Map.get(response_headers, "rscl", ""),
            Map.get(response_headers, "rsct", "")
          ]
          |> Enum.join("\n")

        signature =
          :crypto.mac(:hmac, :sha256, account_key, string_to_sign)
          |> Base.encode64()

        query =
          %{
            "sv" => version,
            "spr" => protocol,
            "se" => expiry_time,
            "sr" => resource,
            "sp" => permissions,
            "sig" => signature
          }
          |> maybe_put("st", start_time)
          |> put_response_header_params(response_headers)
          |> URI.encode_query()

        {:ok, query}
      end
    end

    defp blob_url(key, %AshStorage.Service.Context{} = ctx) do
      opts = ctx.service_opts
      container = Keyword.fetch!(opts, :container)

      "#{endpoint_url(opts)}/#{encode_path_segment(container)}/#{encode_blob_path(key)}"
    end

    defp endpoint_url(opts) do
      account = Keyword.fetch!(opts, :account)

      opts
      |> Keyword.get(:endpoint_url, "https://#{account}.blob.core.windows.net")
      |> String.trim_trailing("/")
    end

    defp prefixed_key(key, %AshStorage.Service.Context{} = ctx) do
      case Keyword.get(ctx.service_opts, :prefix) do
        nil -> key
        "" -> key
        prefix -> "#{prefix}#{key}"
      end
    end

    defp base_headers(%AshStorage.Service.Context{} = ctx) do
      %{"x-ms-version" => service_version(ctx.service_opts)}
    end

    defp service_version(opts) do
      Keyword.get(opts, :service_version, @default_service_version)
    end

    defp signed_protocol(opts) do
      Keyword.get(opts, :signed_protocol) ||
        if String.starts_with?(endpoint_url(opts), "http://") do
          "https,http"
        else
          "https"
        end
    end

    defp resolve_account_key(opts) do
      key =
        Keyword.get(opts, :account_key) ||
          opts
          |> Keyword.get(:account_key_env, @default_account_key_env)
          |> System.get_env()

      case key do
        nil ->
          {:error, :missing_credentials}

        "" ->
          {:error, :missing_credentials}

        key ->
          case Base.decode64(key) do
            {:ok, decoded} -> {:ok, decoded}
            :error -> {:error, :invalid_account_key}
          end
      end
    end

    defp resolve_sas_token(opts) do
      token =
        Keyword.get(opts, :sas_token) ||
          opts
          |> Keyword.get(:sas_token_env, @default_sas_token_env)
          |> System.get_env()

      case token do
        nil ->
          :error

        "" ->
          :error

        token ->
          case normalize_sas_token(token) do
            "" -> :error
            token -> {:ok, token}
          end
      end
    end

    defp normalize_sas_token(token) do
      token
      |> String.trim()
      |> String.trim_leading("?")
    end

    defp append_query(url, ""), do: url

    defp append_query(url, query) do
      separator = if String.contains?(url, "?"), do: "&", else: "?"
      "#{url}#{separator}#{normalize_sas_token(query)}"
    end

    defp expiry_time(opts, service_opts) do
      case Keyword.get(opts, :expires_at) do
        nil ->
          expires_in =
            Keyword.get(opts, :expires_in, Keyword.get(service_opts, :expires_in, 3600))

          DateTime.utc_now() |> DateTime.add(expires_in, :second)

        expires_at ->
          expires_at
      end
    end

    defp format_time(nil), do: ""

    defp format_time(%DateTime{} = datetime) do
      datetime
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
    end

    defp format_time(%NaiveDateTime{} = datetime) do
      datetime
      |> DateTime.from_naive!("Etc/UTC")
      |> format_time()
    end

    defp format_time(value) when is_binary(value), do: value

    defp response_headers(opts) do
      %{}
      |> maybe_put("rscc", Keyword.get(opts, :cache_control))
      |> maybe_put("rscd", content_disposition(opts))
      |> maybe_put("rsce", Keyword.get(opts, :content_encoding))
      |> maybe_put("rscl", Keyword.get(opts, :content_language))
      |> maybe_put("rsct", Keyword.get(opts, :content_type))
    end

    defp content_disposition(opts) do
      Keyword.get(opts, :content_disposition) ||
        case Keyword.get(opts, :disposition) do
          nil -> nil
          disposition -> build_content_disposition(disposition, Keyword.get(opts, :filename))
        end
    end

    defp build_content_disposition(disposition, nil), do: to_string(disposition)

    defp build_content_disposition(disposition, filename) do
      escaped_filename = filename |> to_string() |> String.replace("\"", "\\\"")
      ~s(#{disposition}; filename="#{escaped_filename}")
    end

    defp put_response_header_params(query, response_headers) do
      Enum.reduce(response_headers, query, fn {name, value}, acc ->
        maybe_put(acc, name, value)
      end)
    end

    defp maybe_put(collection, _key, nil), do: collection
    defp maybe_put(collection, _key, ""), do: collection
    defp maybe_put(collection, key, value), do: Map.put(collection, key, value)

    defp encode_blob_path(key) do
      key
      |> String.split("/")
      |> Enum.map_join("/", &encode_path_segment/1)
    end

    defp encode_path_segment(segment) do
      URI.encode(segment, &URI.char_unreserved?/1)
    end
  end
end
