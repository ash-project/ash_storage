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

For polymorphic attachments (shared across multiple resource types), omit `belongs_to_resource`:

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
    extensions: [AshStorage.Resource],
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
    extensions: [AshStorage.Resource],
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
- `AshStorage.Service.S3` — S3-compatible storage (coming soon)

Implement the `AshStorage.Service` behaviour to add custom backends.

## Documentation

- [HexDocs](https://hexdocs.pm/ash_storage)
- [Ash Framework](https://hexdocs.pm/ash)
