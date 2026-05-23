defmodule AshStorage.Service.Disk do
  @moduledoc """
  A storage service that stores files on the local filesystem.

  ## Configuration

      storage do
        service {AshStorage.Service.Disk, root: "priv/storage", base_url: "/files"}
      end

  ## Options

  - `:root` - (required) the root directory for file storage
  - `:base_url` - (required for `url/2`) the base URL for serving files
  - `:secret` - secret key for generating signed URLs. When set, `url/2`
    returns URLs with HMAC tokens that the `AshStorage.Plug.DiskServe`
    plug will verify before serving files.
  - `:expires_in` - default expiration for signed URLs in seconds (default: 3600)

  ## Content-Type

  `upload/3` writes raw bytes to disk and does not persist a Content-Type
  alongside them. `AshStorage.Plug.DiskServe` derives Content-Type from the
  served URL's filename via `MIME.from_path/1`, so attachments served through
  DiskServe should either use the `key/filename` URL form (set the attachment's
  `:original_filename` option) or have keys with meaningful extensions.
  `download/2` uses the same inference to populate `:content_type` for
  in-process consumers like `AshStorage.Plug.Proxy`.
  """

  @behaviour AshStorage.Service

  @impl true
  def service_opts_fields do
    [
      root: [type: :string, allow_nil?: false]
    ]
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def upload(key, io, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)
    path = Path.join(root, key)

    path |> Path.dirname() |> File.mkdir_p!()

    case io do
      %File.Stream{} = stream ->
        stream
        |> Stream.into(File.stream!(path))
        |> Stream.run()

      data when is_binary(data) ->
        File.write(path, data)

      data when is_list(data) ->
        File.write(path, data)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def download(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)
    path = Path.join(root, key)

    with {:ok, data} <- File.read(path),
         :ok <- verify_md5(data, ctx.expected_md5) do
      {:ok, %{body: data, content_type: infer_content_type(key)}}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp infer_content_type(key) do
    case MIME.from_path(key) do
      "application/octet-stream" -> nil
      other -> other
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def delete(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)
    path = Path.join(root, key)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def exists?(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)
    path = Path.join(root, key)
    {:ok, File.exists?(path)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def head(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)
    path = Path.join(root, key)

    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, data} <- File.read(path) do
      {:ok, %{etag: nil, content_md5: Base.encode64(:erlang.md5(data)), byte_size: size}}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def url(key, %AshStorage.Service.Context{} = ctx) do
    opts = ctx.service_opts
    base_url = Keyword.fetch!(opts, :base_url)

    path =
      case Keyword.get(opts, :original_filename) do
        nil -> key
        filename -> "#{key}/#{URI.encode(filename, &URI.char_unreserved?/1)}"
      end

    plain_url = "#{base_url}/#{path}"

    case Keyword.get(opts, :secret) do
      nil ->
        plain_url

      secret ->
        sign_opts =
          []
          |> maybe_put(:expires_in, Keyword.get(opts, :expires_in))
          |> maybe_put(:disposition, Keyword.get(opts, :disposition))
          |> maybe_put(:filename, Keyword.get(opts, :filename))

        AshStorage.Token.signed_url(plain_url, secret, key, sign_opts)
    end
  end

  @impl true
  def direct_upload(key, %AshStorage.Service.Context{} = ctx) do
    base_url = Keyword.fetch!(ctx.service_opts, :base_url)

    content_type =
      ctx.content_type ||
        Keyword.get(ctx.service_opts, :content_type, "application/octet-stream")

    {:ok,
     %{
       url: "#{base_url}/disk/#{key}",
       method: :put,
       headers: %{"content-type" => content_type}
     }}
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp verify_md5(_data, nil), do: :ok

  defp verify_md5(data, expected) do
    if Base.encode64(:erlang.md5(data)) == expected,
      do: :ok,
      else: {:error, :checksum_mismatch}
  end
end
