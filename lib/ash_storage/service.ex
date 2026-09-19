defmodule AshStorage.Service do
  @moduledoc """
  Behaviour for storage service backends.

  A service provides a uniform interface for storing, retrieving, and managing files
  regardless of the underlying storage technology (local disk, S3, GCS, Azure, etc.).

  All callbacks receive an `%AshStorage.Service.Context{}` struct which contains
  the service-specific options as well as broader context (resource, attachment,
  actor, tenant).

  ## Implementing a Service

  To implement a custom storage service, define a module that adopts this behaviour:

      defmodule MyApp.Storage.CustomService do
        @behaviour AshStorage.Service

        @impl true
        def upload(key, data, context) do
          bucket = context.service_opts[:bucket]
          # Upload implementation
        end

        # ... implement all callbacks
      end
  """

  alias AshStorage.Service.Context

  @type key :: String.t()

  @doc """
  Upload a file to the storage service.

  May return `:ok` or `{:ok, extra_blob_attrs}`. When a map is returned, its entries
  are merged into the blob record on creation. This allows wrapping services (e.g.
  encryption) to store per-file metadata such as encryption keys on the blob.

  The Context carries the upload's `:content_type` and `:filename` when set
  by the caller of `attach/4`, so services can record them on the underlying
  object (e.g. the bundled S3 service forwards `:content_type` as the
  `Content-Type` header on PUT). See `AshStorage.Service.Context` for the
  full list of fields.
  """
  @callback upload(key(), iodata() | File.Stream.t(), Context.t()) ::
              :ok | {:ok, map()} | {:error, term()}

  @doc """
  Download a file from the storage service.

  Returns the file contents as raw bytes, regardless of the stored object's
  `content-type`. Callers writing the result to disk or piping it to a client
  get back the exact bytes that were uploaded.

  Services built on `Req` (S3, AzureBlob) disable Req's default `decode_body`
  step to honor this contract — otherwise a `text/csv` object would come back
  as parsed rows and `application/json` as an Elixir map. Services may expose
  a `:decode_body` service option to opt back into content-type decoding when
  that is what the caller wants.
  """
  @callback download(key(), Context.t()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Stream a file's bytes from the storage service.

  Returns an enumerable of binary chunks which, concatenated, are exactly the
  bytes `download/2` would return. Lets callers forward large objects to a
  client without holding the whole body in memory.

  This callback is optional. Call
  `AshStorage.Operations.stream_download_from_service/3` rather than invoking it
  directly — services that don't implement it fall back to `download/2` there
  and yield the body as a single chunk.

  The context's `:expected_md5` is not honored: a service handing out chunks
  cannot hash the body before the caller has seen part of it. Use `download/2`
  when the integrity check matters.

  `{:ok, enumerable}` means the object was confirmed to exist at call time, not
  that every chunk is guaranteed to arrive — enumeration can still raise if the
  object is removed mid-stream. Callers that have already begun writing a
  response should be prepared for that.

  Some implementations return an enumerable that must be consumed in the
  process that called `stream_download/2` (e.g. one backed by a network
  response streamed into the calling process's mailbox) — callers should not
  hand the returned enumerable to another process. Check the implementing
  service's documentation.
  """
  @callback stream_download(key(), Context.t()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Delete a file from the storage service.
  """
  @callback delete(key(), Context.t()) :: :ok | {:error, term()}

  @doc """
  Check if a file exists in the storage service.
  """
  @callback exists?(key(), Context.t()) :: {:ok, boolean()} | {:error, term()}

  @doc """
  Generate a URL for accessing a file.

  Service-specific options like `:expires_in`, `:disposition`, `:filename`,
  and `:content_type` can be passed via the context's service_opts.
  """
  @callback url(key(), Context.t()) :: String.t()

  @doc """
  Upload multiple files to the storage service in bulk.

  Receives a list of `{key, data}` tuples. Services that support bulk/multipart
  uploads can override this for efficiency.
  """
  @callback upload_many([{key(), iodata() | File.Stream.t()}], Context.t()) ::
              :ok | {:error, term()}

  @doc """
  Delete multiple files from the storage service in bulk.

  Services that support bulk deletes can override this for efficiency.
  """
  @callback delete_many([key()], Context.t()) :: :ok | {:error, term()}

  @doc """
  Generate a signed URL or form for direct client-side upload.

  Returns a map with at minimum a `:url` key. Depending on the service,
  it may also include `:headers` (for signed PUT URLs such as S3 presigned
  URLs or Azure SAS URLs) or `:fields` (for S3 presigned POST/form uploads).
  """
  @callback direct_upload(key(), Context.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Read integrity metadata for a stored object without downloading its body.

  Returns `{:ok, info}` with whichever of `:etag`, `:content_md5`, and
  `:byte_size` the service can provide; values the service cannot determine
  are `nil`. Used by `AttachBlob` to confirm direct uploads before linking.

  Services that don't implement this callback skip auto-confirmation; the
  framework logs a warning once per such service module so the gap is visible.
  """
  @callback head(key(), Context.t()) ::
              {:ok,
               %{
                 etag: String.t() | nil,
                 content_md5: String.t() | nil,
                 byte_size: non_neg_integer() | nil
               }}
              | {:error, term()}

  @doc """
  Return the fields from the service opts that should be persisted on the blob
  record for later operations (e.g. async purge).

  Returns a keyword list suitable as the `fields` constraint for `Ash.Type.Keyword`.

  Example:

      def service_opts_fields do
        [
          root: [type: :string],
          bucket: [type: :string],
          region: [type: :string]
        ]
      end

  Services that don't implement this callback cannot be used with async purge.
  """
  @callback service_opts_fields() :: keyword()

  @optional_callbacks upload_many: 2,
                      delete_many: 2,
                      direct_upload: 2,
                      service_opts_fields: 0,
                      head: 2,
                      stream_download: 2
end
