defmodule AshStorage.Service.Disk do
  @moduledoc """
  A storage service that stores files on the local filesystem.

  ## Configuration

      config :ash_storage, :services,
        local: {AshStorage.Service.Disk, root: "priv/storage"}
  """

  @behaviour AshStorage.Service

  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def upload(key, io, opts) do
    root = Keyword.fetch!(opts, :root)
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
  def download(key, opts) do
    root = Keyword.fetch!(opts, :root)
    path = Path.join(root, key)

    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    raise ArgumentError, "delete/1 requires options, use the service configuration. Key: #{key}"
  end

  @doc """
  Delete a file from disk.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def delete(key, opts) do
    root = Keyword.fetch!(opts, :root)
    path = Path.join(root, key)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def exists?(key) do
    raise ArgumentError,
          "exists?/1 requires options, use the service configuration. Key: #{key}"
  end

  @doc """
  Check if a file exists on disk.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def exists?(key, opts) do
    root = Keyword.fetch!(opts, :root)
    path = Path.join(root, key)
    File.exists?(path)
  end

  @impl true
  def url(key, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    "#{base_url}/#{key}"
  end

  @impl true
  def direct_upload_url(key, opts) do
    base_url = Keyword.fetch!(opts, :base_url)

    {:ok,
     %{
       url: "#{base_url}/disk/#{key}",
       headers: %{"content-type" => Keyword.get(opts, :content_type, "application/octet-stream")}
     }}
  end
end
