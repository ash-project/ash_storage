# AshStorage

[![CI](https://github.com/ash-project/ash_storage/actions/workflows/elixir.yml/badge.svg)](https://github.com/ash-project/ash_storage/actions/workflows/elixir.yml)
[![Hex version](https://img.shields.io/hexpm/v/ash_storage.svg)](https://hex.pm/packages/ash_storage)

An [Ash](https://hexdocs.pm/ash) extension for file storage and attachments.

## Installation

Add `ash_storage` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_storage, "~> 0.1.0"}
  ]
end
```

## Setup

AshStorage requires three resources: a **blob** resource to store file metadata, an **attachment** resource to link blobs to records, and one or more **host** resources that declare attachments.

### 1. Blob resource

```elixir
defmodule MyApp.StorageBlob do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage.BlobResource]

  postgres do
    table "storage_blobs"
    repo MyApp.Repo
  end

  blob do
  end

  attributes do
    uuid_primary_key :id
  end
end
```

### 2. Attachment resource

For a single-parent use case with proper foreign keys:

```elixir
defmodule MyApp.StorageAttachment do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage.AttachmentResource]

  postgres do
    table "storage_attachments"
    repo MyApp.Repo
  end

  attachment do
    blob_resource MyApp.StorageBlob
    belongs_to_resource :post, MyApp.Post
  end

  attributes do
    uuid_primary_key :id
  end
end
```

For attachments shared across multiple resource types, declare multiple `belongs_to_resource` entries (foreign keys will be nullable):

```elixir
attachment do
  blob_resource MyApp.StorageBlob
  belongs_to_resource :post, MyApp.Post
  belongs_to_resource :comment, MyApp.Comment
end
```

For fully polymorphic attachments (using `record_type`/`record_id` string columns instead of foreign keys), omit `belongs_to_resource` entirely:

```elixir
attachment do
  blob_resource MyApp.StorageBlob
end
```

### 3. Host resource

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage],
    otp_app: :my_app

  storage do
    service {AshStorage.Service.Disk, root: "priv/storage", base_url: "/storage"}
    blob_resource MyApp.StorageBlob
    attachment_resource MyApp.StorageAttachment

    has_one_attached :cover_image
    has_many_attached :documents
  end

  # ...
end
```

This automatically adds:

- `has_one :cover_image` / `has_many :documents` relationships to load attachments
- A `cover_image_url` calculation for each `has_one_attached`
- A `url` calculation on each attachment record

## Usage

### Attaching files

```elixir
{:ok, %{blob: blob}} =
  AshStorage.Operations.attach(post, :cover_image, file_data,
    filename: "photo.jpg",
    content_type: "image/jpeg"
  )
```

For `has_one_attached`, attaching replaces any existing attachment (the old file is purged). For `has_many_attached`, each attach appends.

### Loading attachments

```elixir
post = Ash.load!(post, :cover_image)
post.cover_image.blob.filename
#=> "photo.jpg"

post = Ash.load!(post, :cover_image_url)
post.cover_image_url
#=> "/storage/a81bf21e2442..."

post = Ash.load!(post, documents: :blob)
Enum.map(post.documents, & &1.blob.filename)
#=> ["report.pdf", "notes.txt"]

# Load URLs via the attachment's url calculation
post = Ash.load!(post, documents: [:url])
Enum.map(post.documents, & &1.url)
#=> ["/storage/a81bf21e2442...", "/storage/f9c3e71d8810..."]
```

### Detaching and purging

```elixir
# Detach (remove link, keep file)
AshStorage.Operations.detach(post, :cover_image)

# Purge (remove link, blob record, and file)
AshStorage.Operations.purge(post, :cover_image)

# For has_many_attached, specify which blob
AshStorage.Operations.detach(post, :documents, blob_id: blob.id)
AshStorage.Operations.purge(post, :documents, blob_id: blob.id)

# Purge all documents
AshStorage.Operations.purge(post, :documents, all: true)
```

### Dependent destroy

Control what happens to attachments when a record is destroyed:

```elixir
storage do
  has_one_attached :cover_image                    # default: dependent: :purge
  has_many_attached :documents, dependent: :detach # keep files, remove links
  has_many_attached :logs, dependent: false         # do nothing
end
```

File deletion happens outside the database transaction, so a failed file delete won't roll back the record destroy.

Soft destroy actions (where `action.soft?` is true) skip dependent attachment handling entirely.

## Configuring the storage service

### Per-resource (DSL)

```elixir
storage do
  service {AshStorage.Service.Disk, root: "priv/storage", base_url: "/storage"}
end
```

### Per-attachment (DSL)

```elixir
storage do
  has_one_attached :avatar, service: {AshStorage.Service.S3, bucket: "avatars"}
end
```

### Per-environment (application config)

Override the service at runtime using application config. This requires `otp_app` on the resource:

```elixir
# The resource
defmodule MyApp.Post do
  use Ash.Resource,
    extensions: [AshStorage],
    otp_app: :my_app
  # ...
end
```

Override the resource-level service:

```elixir
# config/test.exs
config :my_app, MyApp.Post,
  storage: [service: {AshStorage.Service.Test, []}]
```

Override a specific attachment's service:

```elixir
# config/prod.exs
config :my_app, MyApp.Post,
  storage: [
    has_one_attached: [
      avatar: [service: {AshStorage.Service.S3, bucket: "prod-avatars"}]
    ]
  ]
```

Resolution order (first match wins):

1. Per-attachment app config
2. Per-attachment DSL `service` option
3. Resource-level app config
4. Resource-level DSL `service` option

### Switching to a test service

`AshStorage.Service.Test` is an in-memory service for tests. Set it up in your test config:

```elixir
# config/test.exs
config :my_app, MyApp.Post,
  storage: [service: {AshStorage.Service.Test, []}]
```

Then in your test helper or setup:

```elixir
# test/test_helper.exs
AshStorage.Service.Test.start()

# In each test
setup do
  AshStorage.Service.Test.reset!()
  :ok
end
```

## Storage services

AshStorage ships with:

- `AshStorage.Service.Disk` — Local filesystem storage
- `AshStorage.Service.Test` — In-memory storage for tests
- `AshStorage.Service.S3` — S3-compatible storage (requires [`req_s3`](https://hex.pm/packages/req_s3))

Implement the `AshStorage.Service` behaviour to add custom backends.

## Roadmap

- ~~**Analyzers**~~ ✅ — Pluggable metadata extraction (image dimensions, video duration, audio bitrate) stored in blob `analyzers` map. Runs synchronously during attach from local IO by default. With AshOban: optionally enqueue via `analyze: :oban`. Supports `write_attributes` to write results back to parent record attributes. Custom analyzers implement the `AshStorage.Analyzer` behaviour.
- ~~**Variants**~~ ✅ — File transformations: image resizing/conversion, PDF-to-thumbnail, video thumbnails, and any custom transform. Subsumes the previewer concept — a PDF thumbnail is just a variant. Three generation modes: `:on_demand` (default, generated inline on first URL request), `:eager` (during attach), `:oban` (background job via AshOban). Variant blobs are self-referential on the blob resource with digest-based cache invalidation. Named variants declared in DSL via `variant :name, {Module, opts}`. Custom transformers implement `AshStorage.Variant` behaviour.
- **Per-variant oban jobs** — Currently all pending variants for a blob run in a single oban job. Refactor so each variant gets its own job lifecycle, enabling parallel generation and independent retries.
- **Checksum verification** — Integrity checking via checksums on upload
- **Redirect handler** — A plug that redirects to the storage service URL instead of proxying
- **Mirroring** — Mirror service that replicates uploads across multiple backends for redundancy
- **Orphan cleanup** — Periodic cleanup of blobs without files or files without blobs. With AshOban: scheduled job. Without: manual invocation via `AshStorage.Operations.cleanup_orphans/1`.

### Future services

- **GCS** — Google Cloud Storage backend
- **Azure** — Azure Blob Storage backend

### Library options under consideration

These are the Elixir libraries we're evaluating for each roadmap feature. All would be optional dependencies.

#### Image processing (for variants)

| Library | Approach | Notes |
|---|---|---|
| [`image`](https://hex.pm/packages/image) + [`vix`](https://hex.pm/packages/vix) | libvips NIFs | **Recommended.** 2-3x faster than ImageMagick, ~5x less memory. Ships pre-built binaries for macOS/Linux. Supports JPEG, PNG, WebP, TIFF, SVG, HEIF, GIF, AVIF. |
| [`mogrify`](https://hex.pm/packages/mogrify) | ImageMagick shell-out | Legacy option. Well-known but ImageMagick has a much larger CVE surface than libvips. |

#### Image metadata extraction (for analyzers)

| Library | Approach | Notes |
|---|---|---|
| [`ex_image_info`](https://hex.pm/packages/ex_image_info) | Pure Elixir | **Recommended for lightweight use.** Zero deps. Gets dimensions + detected MIME from binary data. Supports JPEG, PNG, GIF, BMP, TIFF, WebP, PSD, SVG, ICO. |
| [`exexif`](https://hex.pm/packages/exexif) | Pure Elixir | EXIF/TIFF metadata from JPEGs (camera info, GPS, exposure). |
| [`image`](https://hex.pm/packages/image) | libvips | Also extracts dimensions and metadata. Good if already using it for variants. |

#### Video/audio metadata and thumbnails (for analyzers + variants)

| Library | Approach | Notes |
|---|---|---|
| [`ffmpex`](https://hex.pm/packages/ffmpex) | FFmpeg shell-out | **Recommended.** Wraps ffprobe for metadata (duration, bitrate, codecs, dimensions) and ffmpeg for thumbnail extraction. Stable, well-understood. |
| [`xav`](https://hex.pm/packages/xav) | FFmpeg NIFs | NIF-based, no shell-out. Part of elixir-webrtc org, actively maintained. Tighter integration but heavier dependency. |
| [`thumbnex`](https://hex.pm/packages/thumbnex) | ImageMagick + FFmpeg | Simple API for thumbnails from images, videos, and PDFs. Uses `convert` for PDFs, `ffmpeg` for videos. |

#### PDF thumbnails (for variants)

| Library | Approach | Notes |
|---|---|---|
| [`image`](https://hex.pm/packages/image) / [`vix`](https://hex.pm/packages/vix) | libvips + poppler | Can render PDF pages to images if libvips is compiled with poppler/PDFium support. Pre-built binaries may or may not include poppler. |
| [`thumbnex`](https://hex.pm/packages/thumbnex) | ImageMagick shell-out | Uses `convert` to render first page. Requires ImageMagick with Ghostscript. |

#### File type detection / content sniffing (for analyzers)

| Library | Approach | Notes |
|---|---|---|
| [`gen_magic`](https://hex.pm/packages/gen_magic) | libmagic NIF | Most accurate — uses the same library behind the Unix `file` command. Supervised process with pooling. Requires `libmagic` system dep. |
| [`ex_marcel`](https://hex.pm/packages/ex_marcel) | Pure Elixir | Port of Rails' Marcel gem (used by ActiveStorage). Uses Apache Tika signature data. No system deps. |
| [`magic_number`](https://hex.pm/packages/magic_number) | Pure Elixir | Lightweight magic number matching. Older, less actively maintained. |

## Documentation

- [HexDocs](https://hexdocs.pm/ash_storage)
- [Ash Framework](https://hexdocs.pm/ash)
