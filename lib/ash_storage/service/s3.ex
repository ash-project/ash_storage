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
  """

  @behaviour AshStorage.Service

  @impl true
  def upload(key, data, %AshStorage.Service.Context{} = ctx) do
    full_key = prefixed_key(key, ctx)

    case Req.put(req(ctx), url: "/#{full_key}", body: data) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def download(key, %AshStorage.Service.Context{} = ctx) do
    full_key = prefixed_key(key, ctx)

    case Req.get(req(ctx), url: "/#{full_key}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
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
        |> maybe_put(:expires_in, Keyword.get(opts, :expires_in))

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
      |> maybe_put(:access_key_id, resolve_credential(opts, :access_key_id, "AWS_ACCESS_KEY_ID"))
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
      |> maybe_put(:access_key_id, resolve_credential(opts, :access_key_id, "AWS_ACCESS_KEY_ID"))
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
      prefix -> "#{prefix}#{key}"
    end
  end

  defp resolve_credential(opts, key, env_var) do
    Keyword.get(opts, key) || System.get_env(env_var)
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
