defmodule AshStorage.Service.Disk do
  @moduledoc """
  A storage service that stores files on the local filesystem.

  ## Configuration

      storage do
        service {AshStorage.Service.Disk, root: "priv/storage", base_url: "/files"}
      end

  Files are served by `AshStorage.Plug.DiskServe` mounted at `base_url`. By
  default they are sent as downloads; see the plug's `:inline` option and
  [Serving files](serving.md).

  ## Options

  - `:root` - (required) the root directory for file storage
  - `:base_url` - (required for `url/2`) the base URL for serving files
  - `:secret` - secret key for generating signed URLs. When set, `url/2`
    returns URLs with HMAC tokens that the `AshStorage.Plug.DiskServe`
    plug will verify before serving files.
  - `:expires_in` - default expiration for signed URLs in seconds (default: 3600)
  - `:owner_only` - when `true` (the default), files are written with mode
    `0600` and directories are created with mode `0700`. Set it to `false` to
    leave the modes to the umask of the process. Any other value raises
    `ArgumentError`. See "File modes" below.
  - `:chunk_size` - bytes per chunk for `stream_download/2` (default: `65_536`).
    Only `:root` is persisted per `service_opts_fields/0`, so this is honored
    when the context carries live service opts (calling `stream_download/2`
    directly) but not when the context is rebuilt from a blob record via
    `AshStorage.Operations.stream_download/2`, which always uses the default.

  ## File modes

  By default only the operating system user that runs the application can read
  what the service stores. `upload/3` gives every file it writes the mode
  `0600`, also when it replaces a file, and gives the directories it creates,
  including a missing root, the mode `0700`. Directories that already exist
  keep their mode, and so do files that were stored earlier. When a mode cannot
  be set, the upload fails with the error from the file system.

  Set `owner_only: false` when another user has to read the files, for example
  a web server that serves the root itself, and control the modes with the
  umask. On Windows the option has no effect.
  """

  @behaviour AshStorage.Service

  @default_chunk_size 65_536
  @file_mode 0o600
  @directory_mode 0o700

  @impl true
  def service_opts_fields do
    [
      root: [type: :string, allow_nil?: false]
    ]
  end

  @impl true
  def upload(key, io, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)
    owner_only? = owner_only!(ctx.service_opts)

    with {:ok, safe_path} <- safe_file_path(root, key),
         :ok <- ensure_directory(Path.dirname(safe_path), owner_only?),
         :ok <- prepare_file(safe_path, owner_only?) do
      write_file(safe_path, io)
    end
  end

  defp owner_only!(opts) do
    case Keyword.get(opts, :owner_only, true) do
      value when is_boolean(value) ->
        value

      other ->
        raise ArgumentError,
              "invalid :owner_only option #{inspect(other)}. Expected true or false"
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_file(path, io) do
    case io do
      %File.Stream{} = stream ->
        stream
        |> Stream.into(File.stream!(path))
        |> Stream.run()

      data when is_binary(data) or is_list(data) ->
        File.write(path, data)
    end
  end

  # Creates the missing directories one level at a time, so that the mode is
  # set on the directories this call creates and on no others.
  defp ensure_directory(dir, owner_only?) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- ensure_directory(Path.dirname(dir), owner_only?) do
        make_directory(dir, owner_only?)
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp make_directory(dir, owner_only?) do
    case File.mkdir(dir) do
      :ok when owner_only? -> File.chmod(dir, @directory_mode)
      :ok -> :ok
      # another upload created it first
      {:error, :eexist} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp prepare_file(_path, false), do: :ok

  # The mode is set while the file is still empty (or still holds the old
  # content, when it is being replaced), so the new content is not written
  # under the umask's mode. This narrows the window, it does not close it: a
  # process that opened the file before the `chmod` keeps its handle. Opening
  # for append creates the file without truncating it and fails on a directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare_file(path, true) do
    with {:ok, device} <- File.open(path, [:append]),
         :ok <- File.close(device) do
      File.chmod(path, @file_mode)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def download(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    with {:ok, safe_path} <- safe_file_path(root, key),
         {:ok, data} <- File.read(safe_path),
         :ok <- verify_md5(data, ctx.expected_md5) do
      {:ok, data}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def stream_download(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)
    chunk_size = Keyword.get(ctx.service_opts, :chunk_size, @default_chunk_size)

    with {:ok, safe_path} <- safe_file_path(root, key),
         {:ok, %File.Stat{type: :regular}} <- File.stat(safe_path) do
      {:ok, File.stream!(safe_path, chunk_size)}
    else
      {:ok, %File.Stat{}} ->
        {:error, :eisdir}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def delete(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    with {:ok, safe_path} <- safe_file_path(root, key),
         :ok <- File.rm(safe_path) do
      :ok
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def exists?(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    case safe_file_path(root, key) do
      {:ok, safe_path} ->
        {:ok, File.exists?(safe_path)}

      {:error, _} = err ->
        err
    end
  end

  # sobelow_skip ["Crypto.WeakHash", "Traversal.FileModule"]
  @impl true
  def head(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    with {:ok, safe_path} <- safe_file_path(root, key),
         {:ok, %File.Stat{size: size}} <- File.stat(safe_path),
         {:ok, data} <- File.read(safe_path) do
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

    {:ok,
     %{
       url: "#{base_url}/disk/#{key}",
       method: :put,
       headers: %{
         "content-type" =>
           Keyword.get(ctx.service_opts, :content_type, "application/octet-stream")
       }
     }}
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp verify_md5(_data, nil), do: :ok

  # sobelow_skip ["Crypto.WeakHash"]
  defp verify_md5(data, expected) do
    if Base.encode64(:erlang.md5(data)) == expected,
      do: :ok,
      else: {:error, :checksum_mismatch}
  end

  defp safe_file_path(root, key) do
    case Path.safe_relative(key, root) do
      {:ok, path} ->
        {:ok, Path.join(root, path)}

      :error ->
        {:error, :einval}
    end
  end
end
