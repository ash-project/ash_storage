# Layers

Layers are optional modules in AshStorage's logical file IO path. They are
implemented through BlobIO and run above storage services: services still
upload, download, delete, prepare direct uploads, and generate service URLs,
while layers can transform bytes, persist per-blob metadata, or adjust serving
policy before the service is called.

Use a layer when a concern must apply consistently across more than one IO
entry point and may need blob context or durable metadata. Use a variant for
derived files, an analyzer for accepted-file inspection, and service
configuration or a custom service for adapter-specific buckets, headers, or
credentials.

See [Encryption](encryption.md) for the bundled encryption layer and
key-management examples, and the `AshStorage.BlobIO` moduledoc for the
lower-level IO boundary these layers run on.

## Rolling out a byte-transforming layer

Adding a byte-transforming layer (such as encryption) to a resource or
attachment changes the stored representation for blobs written from then on. Roll
the layer configuration out to every node before writes begin producing layered
blobs: every web node, proxy route, direct-upload path, variant generator,
analyzer, and background worker that may read those blobs needs the layer configured.

A node that lacks the configuration fails closed rather than mis-serving — a read
of a blob whose persisted metadata names a layer the node has not configured
returns a structured missing-layer error instead of raw, still-transformed bytes.

## Configuration

Configure layers with `layer` entries in the storage DSL, on an attachment, or
as an explicit per-call handoff for raw key-based operations:

```elixir
storage do
  service {AshStorage.Service.S3, bucket: "private-blobs"}

  layer {MyApp.Storage.StoredByteCompression,
         codec: :zstd_dictionary,
         dictionary: :legal_documents}

  has_one_attached :document do
    layer {MyApp.Storage.TamperEvidentEnvelope, profile: :documents}
  end
end
```

Resource-level layers apply first and attachment-level layers apply second.
Operation-level layers are explicit handoffs for routes or workers that have
already resolved the correct layer chain outside of the DSL.

Use `metadata_key` when a configured layer instance needs a stable persisted
identity, especially when the same layer module may appear more than once:

```elixir
layer {AshStorage.Layer.Encryption,
       key_manager: {MyApp.DocumentKeyManager, policy: :documents}},
      metadata_key: "document-envelope"
```

BlobIO stores the metadata key as the persisted layer metadata key. Changing it
for existing blobs is a data compatibility change.

## Writing a layer

A layer is a module implementing the `AshStorage.Layer` behaviour. The
core hooks are `write/2` and `read/2`, which transform the logical bytes, and
`default_metadata_key/1`, which returns the layer's default persisted identity —
usually a plain string. Read the bytes with `Layer.data/1` and replace them with
`Layer.put_data/2`; persist durable per-blob metadata with `Layer.put_metadata/3`
and read it back on the read side. Use `Layer.layer_metadata_key/1` when you need
the *effective* key (default plus any configured override) for persisting or
matching metadata.

```elixir
defmodule MyApp.Storage.StoredByteCompression do
  @behaviour AshStorage.Layer

  alias AshStorage.Layer

  @impl true
  def default_metadata_key(_opts), do: "compression"

  @impl true
  def write(write, opts) do
    {:ok,
     write
     |> Layer.put_metadata(Layer.layer_metadata_key({__MODULE__, opts}), %{"codec" => "zstd"})
     |> Layer.put_data(MyApp.Codec.compress(Layer.data(write)))}
  end

  @impl true
  def read(read, _opts) do
    {:ok, Layer.put_data(read, MyApp.Codec.decompress(Layer.data(read)))}
  end
end
```

You return only the default; configuring `metadata_key: "…"` on the layer (needed
when the same module appears more than once) overrides it, and AshStorage applies
that override wherever the effective key is used — including
`Layer.layer_metadata_key/1` above — so a configured key is never silently
dropped.

`write/2` runs before the service upload; `read/2` runs after the service
download, in reverse order (see [Ordering](#ordering)). Both return
`{:ok, operation}` or `{:error, reason}`, and must hand back the same operation
struct they received. The remaining callbacks are optional: `serving/2` adjusts
serving policy, `direct_upload/2` adjusts or rejects direct-upload preparation,
and a layer that needs the created blob row registers a post-create step with
`Layer.finalize/3` (see [Write finalization](#write-finalization)).

## Durable metadata

Layer metadata is stored on blob records under
`metadata["ash_storage"]["blob_io"]["layers"]`. Only layer metadata keys and
durable layer metadata are persisted. Runtime modules, key-manager modules,
vault modules, plaintext keys, raw secrets, credentials, and policy modules
stay in runtime configuration.

Each metadata entry identifies the durable layer metadata key, not just the
module currently configured to implement it:

```elixir
%{
  "layer_metadata_key" => "primary-blob-vault",
  "metadata" => %{
    "format" => "aes-256-gcm",
    "wrapped_dek" => %{"format" => "cloak", "ciphertext" => "..."}
  }
}
```

Use stable layer metadata keys. Existing blobs use persisted layer metadata keys
to find the runtime layer modules and options that can interpret their metadata.
That lets applications rename modules, change default options, rotate
key-manager policy, or split resource-level and attachment-level configuration
without making older blobs unreadable.

Version durable layer payloads inside the layer's own metadata when the payload
format needs it. BlobIO does not add a generic outer version field, because a
version without reader semantics creates an ambiguous migration contract.

## Ordering

Writes run layers in configured order. Reads use the persisted metadata to
select the layers that actually touched the blob, then run those layers in
reverse order so the logical bytes are reconstructed.

Think of the layer stack as wrapping bytes on write and unwrapping them on
read:

```text
write: logical bytes -> layer A -> layer B -> stored service bytes
read:  stored service bytes -> layer B -> layer A -> logical bytes
```

The last write layer is closest to the bytes stored by the service. The first
configured layer is the outermost logical concern once bytes have been read
back.

For example, a write stack of:

```elixir
[
  {MyApp.Storage.StoredByteCompression,
   codec: :zstd_dictionary,
   dictionary: :legal_documents},
  {AshStorage.Layer.Encryption, layer_metadata_key: "document-envelope", ...}
]
```

first encodes the logical bytes for storage, then encrypts the encoded result
before upload. A later read matches those layer metadata keys against current
runtime configuration, decrypts first, then runs the stored-byte compression
layer's `read/2` callback to reconstruct logical bytes.

If persisted metadata names a layer metadata key that is not configured at read
time, BlobIO returns a structured missing-layer error rather than silently
reading raw service bytes.

## Write finalization

The write phase has a first-class post-create step. While transforming a write,
a layer registers a finalization closure with `Layer.finalize/3`:

```elixir
def write(write, opts) do
  # ... transform bytes / metadata ...
  {:ok, Layer.finalize(write, layer_metadata_key(opts), fn post_create ->
    # post_create.blob now exists; do the side effect and return :ok or {:error, _}
    create_external_grant(post_create.blob, captured_state)
  end)}
end
```

After the service upload and `Ash.create`, the writer builds a single
`AshStorage.BlobIO.Operation.PostCreate` context (the created `blob` plus the
surrounding write state) and invokes each registered closure in configured write
order. This replaces the older second `write_finalized/2` callback: there is one
state channel (the closure, which captures exactly what the layer needs) instead
of opaque state re-derived in a separate callback.

Use this for work that needs the created blob id but should still live inside
the logical BlobIO path, such as an encryption key manager creating external
envelope or grant rows. The closure is runtime-only — never persisted in blob
metadata, possibly carrying sensitive material — so keep it narrow and avoid
logging it. Because it runs **after** the object and row are committed, a
finalization that fails leaves a persisted blob whose finalization did not
complete; closures should be idempotent and the application owns any
compensating cleanup.

## Serving

Serving is a BlobIO phase. Layers can mark a blob as not servable, force proxy
serving, or adjust serving options before AshStorage chooses between a service
URL and a proxy URL. A simple proxy route does not require a layer; use a layer
when the serving decision depends on blob context, persisted layer metadata, or
the same policy also needs to affect reads, writes, or direct-upload
preparation.

Configure a blob-aware proxy by pointing the plug at the host resource and
attachment:

```elixir
forward "/storage", AshStorage.Plug.Proxy,
  resource: MyApp.Post,
  attachment: :document,
  access: {:signed, secret: "proxy-signing-secret"}
```

The proxy resolves the blob by key, uses the blob's stored service metadata,
and reads through the attachment's layer configuration. Use this shape
for layers that need persisted blob metadata, such as encryption.

Use `access: :public` only for routes that are intentionally public. Signed
proxy access verifies that the application minted a still-valid URL, but it is
a bearer capability rather than per-request actor authorization.

If a proxy route does not map cleanly to a single attachment, configure
`:blob_resource` and pass the resolved `:layers` explicitly.

## Key-only handoffs

Key-only operations such as `AshStorage.BlobIO.read_key/4` and generic proxy
routes do not have enough information to rediscover attachment configuration.
Pass the resolved layer chain explicitly to those paths.

If a layer also needs persisted layer metadata, use a blob-aware path that
resolves the blob record and calls `AshStorage.BlobIO.read/3`. A raw key alone
cannot provide metadata such as an encryption envelope.

## Direct uploads

Direct uploads are layer-aware, but not every layer can support them. A layer
that needs the server to inspect or transform bytes may reject direct-upload
preparation with a clear error.

Use an application-owned staging workflow when the product needs
client-to-storage upload ergonomics together with server-side logical write
behavior. In that model, the client uploads to a temporary location and a
privileged server worker later writes the canonical blob through BlobIO.

## Common layer families

- **Envelope encryption:** bidirectional byte transformation with durable
  envelope metadata. This is bundled as
  `AshStorage.Layer.Encryption`.
- **Stored-byte encoding:** reversible compression or packaging that changes
  the bytes at rest and must be undone before callers see logical bytes. Plain
  HTTP compression usually belongs in the HTTP layer instead.
- **Serving policy:** force proxy serving, reject URLs for protected blobs, or
  apply disposition defaults when the decision belongs in the logical BlobIO
  path.
- **Read-enforced integrity envelopes:** write and verify signatures or
  stronger application-specific integrity metadata on read. Ordinary MD5
  checksum verification is handled by AshStorage's service/read paths.
- **Access audit hooks:** record read, write, direct-upload, or serving
  decisions when those decisions happen inside the BlobIO path.

Some storage concerns should remain outside layers. Watermarks, previews,
redactions, thumbnails, transcodes, and document normalization usually produce
new blobs and fit variants or application-owned jobs. Malware scanning, OCR,
and classification usually inspect an accepted blob and fit analyzers or
background jobs. Tenant prefixes, object key naming, and per-attachment storage
paths usually belong in service options or application-level key derivation.
HTTP response compression, cache headers, range behavior, and simple content
disposition usually belong in plugs, service URL options, or the HTTP layer.
Retention and legal hold usually belong in resource policies or
service-specific object-lock configuration unless they must participate in the
logical BlobIO path.
