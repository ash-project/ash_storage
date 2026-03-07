defmodule AshStorage.Service do
  @moduledoc """
  Behaviour for storage service backends.

  A service provides a uniform interface for storing, retrieving, and managing files
  regardless of the underlying storage technology (local disk, S3, GCS, Azure, etc.).

  ## Implementing a Service

  To implement a custom storage service, define a module that adopts this behaviour:

      defmodule MyApp.Storage.CustomService do
        @behaviour AshStorage.Service

        @impl true
        def upload(key, io, opts) do
          # Upload implementation
        end

        # ... implement all callbacks
      end
  """

  @type key :: String.t()
  @type upload_opts :: keyword()
  @type download_opts :: keyword()

  @doc """
  Upload a file to the storage service.

  ## Options

  - `:content_type` - The MIME type of the file
  - `:checksum` - Base64-encoded MD5 digest for integrity verification
  - `:metadata` - Additional metadata to store with the file
  """
  @callback upload(key(), iodata() | File.Stream.t(), upload_opts()) ::
              :ok | {:error, term()}

  @doc """
  Download a file from the storage service.

  Returns the file contents as binary data.
  """
  @callback download(key(), download_opts()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Delete a file from the storage service.
  """
  @callback delete(key()) :: :ok | {:error, term()}

  @doc """
  Check if a file exists in the storage service.
  """
  @callback exists?(key()) :: boolean()

  @doc """
  Generate a URL for accessing a file.

  ## Options

  - `:expires_in` - Number of seconds until the URL expires (for signed URLs)
  - `:disposition` - Content disposition (`:inline` or `:attachment`)
  - `:filename` - Filename for content disposition
  - `:content_type` - Content type for the response
  """
  @callback url(key(), keyword()) :: String.t()

  @doc """
  Generate headers and URL for a direct upload from the client.

  Returns a map with `:url` and `:headers` keys that the client can use
  to upload directly to the storage service.
  """
  @callback direct_upload_url(key(), keyword()) ::
              {:ok, %{url: String.t(), headers: map()}} | {:error, term()}
end
