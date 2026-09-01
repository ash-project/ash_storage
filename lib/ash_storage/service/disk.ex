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
  """

  @behaviour AshStorage.Service

  @impl true
  def service_opts_fields do
    [
      root: [type: :string, allow_nil?: false]
    ]
  end

  @impl true
  def upload(key, io, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    with {:ok, path} <- safe_path(root, key) do
      write_io(path, io)
    end
  end

  @impl true
  def download(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    with {:ok, path} <- safe_path(root, key),
         {:ok, data} <- read_file(path),
         :ok <- verify_md5(data, ctx.expected_md5) do
      {:ok, data}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    with {:ok, path} <- safe_path(root, key) do
      case remove_file(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def exists?(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    with {:ok, path} <- safe_path(root, key) do
      {:ok, file_exists?(path)}
    end
  end

  @impl true
  def head(key, %AshStorage.Service.Context{} = ctx) do
    root = Keyword.fetch!(ctx.service_opts, :root)

    with {:ok, path} <- safe_path(root, key),
         {:ok, %File.Stat{size: size}} <- stat_file(path),
         {:ok, data} <- read_file(path) do
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

  # Storage keys arrive from untrusted callers (e.g. a public proxy route).
  # `Path.join/2` does NOT collapse `..`, so resolve the key to a guaranteed-safe
  # relative path before any filesystem access. `Path.safe_relative/2` rejects
  # absolute paths and any `..` that would escape, AND — given `root` — evaluates
  # symlink containment against `root` rather than the process CWD, so a symlink
  # planted under `root` cannot redirect a read/write outside it.
  defp safe_path(root, key) do
    case Path.safe_relative(to_string(key), root) do
      {:ok, relative} -> {:ok, Path.join(root, relative)}
      :error -> {:error, {:unsafe_storage_key, key}}
    end
  end

  # File operations are isolated behind safe_path/2 above; the path can no longer
  # be steered outside `root`, which is what these sobelow skips assert.
  # Stored bytes default to owner-only permissions (files 0o600, dirs 0o700)
  # rather than inheriting the process umask, so blobs are not world-readable on
  # a shared host. The chmod is best-effort and applied after creation.
  @dir_mode 0o700
  @file_mode 0o600

  # sobelow_skip ["Traversal.FileModule"]
  defp write_io(path, io) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    _ = File.chmod(dir, @dir_mode)

    result =
      case io do
        %File.Stream{} = stream ->
          stream |> Stream.into(File.stream!(path)) |> Stream.run()
          :ok

        data when is_binary(data) or is_list(data) ->
          File.write(path, data)
      end

    case result do
      :ok ->
        _ = File.chmod(path, @file_mode)
        :ok

      other ->
        other
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path), do: File.read(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_file(path), do: File.rm(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp file_exists?(path), do: File.exists?(path)

  # sobelow_skip ["Traversal.FileModule"]
  defp stat_file(path), do: File.stat(path)

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp verify_md5(_data, nil), do: :ok

  defp verify_md5(data, expected) do
    if Base.encode64(:erlang.md5(data)) == expected,
      do: :ok,
      else: {:error, :checksum_mismatch}
  end
end
