defmodule AshStorage.BlobIO do
  @moduledoc """
  Logical blob IO boundary.

  `AshStorage.BlobIO` is the IO boundary between AshStorage resources/attachments
  and storage services. Reads, writes, direct-upload preparation, URL generation,
  proxy serving, variants, analyzers, and application background jobs all pass
  through the same context-aware path, instead of each caller reaching into a storage
  service with its own state shape. Services keep doing adapter work
  (upload/download/delete/url/direct-upload); BlobIO owns the context around those
  calls. Unlayered blobs are stored as-is.

  This is a lower-level API: most applications use it indirectly through attaches,
  loads, and proxy serving. Reach for it directly from custom workers (e.g. Oban
  jobs) that read or write blob bytes.

  ## Blob context and phase operations

  `AshStorage.BlobIO.BlobContext` carries the resource, attachment, record, blob,
  actor, tenant, and logical `operation` through the IO path. Each phase then uses
  a narrower operation struct (`Reader.Operation`, `Writer.Operation`,
  `Serving.Operation`, `DirectUploads.Operation`), keeping service adapters small
  while giving layers and higher-level features the state they need.

  ## Reading and writing

    * `read/3` — read a persisted blob's logical bytes; required for layers that
      need persisted blob metadata (such as encryption).
    * `read_key/4` — read raw bytes for a `{service, key}` pair with no blob row;
      useful for ordinary proxying but cannot recover persisted layer metadata.
    * `write/3` — write logical bytes and create the blob row, running write layers
      and post-create finalizations.

  ## Layers

  Layers are ordered modules — configured on the `storage` DSL, on an attachment,
  or supplied explicitly per call — that transform bytes, affect serving, or
  persist durable per-blob metadata. Writes persist layer metadata keys + metadata
  on the blob; reads use that to select and order the runtime layer chain and
  **fail closed** if a persisted layer has no configured runtime match, rather than
  serving raw, still-transformed bytes. A byte-transforming layer such as encryption
  changes the stored representation — see the rollout note in the `Layers` guide.
  The bundled encryption layer is `AshStorage.Layer.Encryption`.

  See the `Layers` and `Encryption` guides for the layer model, metadata, serving
  policy, and encryption/key-management examples.

  ## Application background jobs

  Application-owned background jobs (e.g. Oban) that process blobs should treat
  BlobIO as the storage boundary. Carry durable identity in the payload — blob id, resource module or
  known worker type, attachment name, tenant, and output/finalization data — not
  storage keys, raw service options, plaintext DEKs, or large byte payloads. The
  worker loads the blob, rebuilds an `AshStorage.BlobIO.BlobContext`, and calls
  `read/3` (and `write/3` for derived output), then finalizes the domain
  relationship through its own Ash action or workflow.
  """

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.DirectUploads
  alias AshStorage.BlobIO.Reader
  alias AshStorage.BlobIO.Serving
  alias AshStorage.BlobIO.Writer

  @doc "Read a blob's logical bytes from its configured storage service."
  def read(blob, %BlobContext{} = bctx, opts \\ []) when is_list(opts) do
    Reader.read(blob, bctx, opts)
  end

  @doc "Read raw service bytes for a key through the logical BlobIO boundary."
  def read_key(key, service, %BlobContext{} = bctx, opts \\ []) when is_list(opts) do
    Reader.read_key(key, service, bctx, opts)
  end

  @doc "Return the current serving strategy for a blob."
  def serving_strategy(blob, %BlobContext{} = bctx, opts \\ []) when is_list(opts) do
    Serving.strategy(blob, bctx, opts)
  end

  @doc "Return a URL for servable blobs, or `nil` otherwise."
  def url(blob, %BlobContext{} = bctx, opts \\ []) when is_list(opts) do
    Serving.url(blob, bctx, opts)
  end

  @doc "Create a pending blob record and return service-specific direct upload info."
  def prepare_direct_upload(%BlobContext{} = bctx, opts) when is_list(opts) do
    DirectUploads.prepare(bctx, opts)
  end

  @doc """
  Write logical bytes to storage and create a blob record.

  Options:

  - `:filename` - required filename stored on the blob.
  - `:content_type` - MIME type, defaults to `"application/octet-stream"`.
  - `:metadata` - blob metadata, defaults to `%{}`.
  - `:service` - optional `{service_mod, service_opts}` tuple. Defaults to
    resolving the service from `bctx.resource` and `bctx.attachment`.
  - `:ash_opts` - options passed to `Ash.create/3`.
  - `:action` - create action, defaults to `:create`.
  - `:blob_attrs` - additional blob attributes, e.g. variant linkage.
  - `:layers` - optional layer modules or `{module, opts}` tuples.
  """
  def write(input, %BlobContext{} = bctx, opts) when is_list(opts) do
    Writer.write(input, bctx, opts)
  end
end
