# Direct Uploads

Direct uploads let clients upload files straight to your storage backend (S3, MinIO, Azure Blob Storage, etc.) without proxying through your server. This is the recommended approach for large files — it keeps your application server out of the data path.

The flow has two steps:

1. **Prepare** — your server creates a blob record and returns a presigned URL
2. **Attach** — the client uploads to the presigned URL, then includes the `blob_id` in a normal create/update action

## Setup

Direct uploads require a storage service that supports presigned URLs. `AshStorage.Service.S3` and `AshStorage.Service.AzureBlob` support this out of the box:

```elixir
storage do
  service {AshStorage.Service.S3,
    bucket: "my-app-uploads",
    region: "us-east-1",
    presigned: true}

  blob_resource MyApp.StorageBlob
  attachment_resource MyApp.StorageAttachment

  has_one_attached :cover_image
end
```

For Azure Blob Storage:

```elixir
storage do
  service {AshStorage.Service.AzureBlob,
    account: "myaccount",
    container: "uploads",
    account_key_env: "AZURE_STORAGE_ACCOUNT_KEY",
    presigned: true}

  blob_resource MyApp.StorageBlob
  attachment_resource MyApp.StorageAttachment

  has_one_attached :cover_image
end
```

Azure browser uploads require CORS on the storage account and the `x-ms-blob-type: BlockBlob` request header. `AshStorage.Service.AzureBlob.direct_upload/2` includes that header in the returned upload info.

Azure-specific checklist:

- Create the blob container before uploads begin; the service creates blobs, not containers.
- Configure Blob service CORS for your browser origin, `PUT`/`OPTIONS`, and the request headers your client sends, including `x-ms-blob-type` and `content-type`.
- Prefer `:account_key_env` or `:sas_token_env` over literal secrets. Literal `:account_key` and `:sas_token` values work for immediate service requests but are not persisted on blob records. Use env-backed credentials for attachment flows that later operate from stored blobs, including purge, analysis, and variants.
- If you provide a static SAS token via `:sas_token`/`:sas_token_env`, it is reused for every Azure operation. Use a container/account SAS with the needed permissions: read (`r`) for URLs/downloads/existence checks, create/write (`c`, `w`) for uploads/direct uploads, and delete (`d`) for purges.

Add the `AshStorage.Changes.AttachBlob` change to your create or update actions:

```elixir
actions do
  create :create do
    accept [:title]
    argument :cover_image_blob_id, :uuid, allow_nil?: true

    change {AshStorage.Changes.AttachBlob,
            argument: :cover_image_blob_id, attachment: :cover_image}
  end

  update :update do
    accept [:title]
    require_atomic? false
    argument :cover_image_blob_id, :uuid, allow_nil?: true

    change {AshStorage.Changes.AttachBlob,
            argument: :cover_image_blob_id, attachment: :cover_image}
  end
end
```

When `cover_image_blob_id` is `nil`, the change is skipped. For `has_one_attached`, an existing attachment is replaced (old file purged). For `has_many_attached`, it appends.

## Step 1: Prepare the upload

Call `prepare_direct_upload/3` to create a blob record and get a presigned URL:

```elixir
{:ok, %{blob: blob, url: url, method: method}} =
  AshStorage.Operations.prepare_direct_upload(MyApp.Post, :cover_image,
    filename: "photo.jpg",
    content_type: "image/jpeg",
    byte_size: 1_234_567
  )
```

The returned map contains:

- `:blob` — the created blob record (not yet attached to anything)
- `:url` — the presigned URL to upload to
- `:method` — `:put` or `:post` depending on configuration
- `:headers` — headers to include with the direct upload, when required by the service

For S3 presigned POST (multipart form uploads), you also get `:fields` — a list of form fields to include.

### Presigned PUT vs POST

By default, S3 uses presigned PUT URLs. To use presigned POST forms instead:

```elixir
service {AshStorage.Service.S3,
  bucket: "my-app-uploads",
  direct_upload_method: :post}
```

The JS example below is for presigned PUT. For presigned POST, build a `FormData` with the returned `:fields` (each as a form field), append the file last, and `POST` it as `multipart/form-data` — do not set `Content-Type` manually or send the raw file as the body.

## Step 2: Client uploads and attaches

Send the presigned URL and blob ID to your client. The client uploads directly to storage, then includes the blob ID in a normal create or update:

```javascript
// 1. Upload directly to storage
const uploadHeaders = new Headers(prepareResponse.headers || {});
uploadHeaders.set("Content-Type", file.type);

await fetch(prepareResponse.url, {
  method: prepareResponse.method || "PUT",
  body: file,
  headers: uploadHeaders
});

// 2. Create the record with the blob attached
await fetch("/api/posts", {
  method: "POST",
  body: JSON.stringify({
    title: "My Post",
    cover_image_blob_id: blobId
  })
});
```

No separate confirm step — the blob is attached as part of the normal action.

## Phoenix LiveView example

```elixir
defmodule MyAppWeb.PostLive.Upload do
  use MyAppWeb, :live_view

  def handle_event("request_upload", %{"filename" => filename, "content_type" => type, "byte_size" => size}, socket) do
    {:ok, info} =
      AshStorage.Operations.prepare_direct_upload(MyApp.Post, :cover_image,
        filename: filename,
        content_type: type,
        byte_size: size
      )

    {:reply,
     %{
       url: info.url,
       method: info.method,
       headers: Map.get(info, :headers, %{}),
       blob_id: info.blob.id
     }, socket}
  end

  def handle_event("create_post", %{"title" => title, "blob_id" => blob_id}, socket) do
    MyApp.Post
    |> Ash.Changeset.for_create(:create, %{title: title, cover_image_blob_id: blob_id})
    |> Ash.create!()

    {:noreply, push_navigate(socket, to: ~p"/posts")}
  end
end
```

## `has_many_attached`

Direct uploads work the same way with `has_many_attached`. Each action call with a blob ID appends a new attachment:

```elixir
update :add_document do
  require_atomic? false
  argument :document_blob_id, :uuid, allow_nil?: true

  change {AshStorage.Changes.AttachBlob,
          argument: :document_blob_id, attachment: :documents}
end
```

## Options

`prepare_direct_upload/3` accepts:

| Option | Required | Default | Description |
|---|---|---|---|
| `:filename` | yes | | Original filename |
| `:content_type` | no | `"application/octet-stream"` | MIME type |
| `:byte_size` | no | `0` | Expected file size in bytes |
| `:checksum` | no | `""` | Expected MD5 checksum |
| `:metadata` | no | `%{}` | Custom metadata to store on the blob |

## AshJsonApi

Expose your actions as routes. For the prepare step, add a generic action:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    extensions: [AshStorage, AshJsonApi]

  actions do
    create :create do
      accept [:title]
      argument :cover_image_blob_id, :uuid, allow_nil?: true

      change {AshStorage.Changes.AttachBlob,
              argument: :cover_image_blob_id, attachment: :cover_image}
    end

    action :prepare_cover_image_upload, :map do
      argument :filename, :string, allow_nil?: false
      argument :content_type, :string, default: "application/octet-stream"
      argument :byte_size, :integer, default: 0

      run fn input, _context ->
        AshStorage.Operations.prepare_direct_upload(__MODULE__, :cover_image,
          filename: input.arguments.filename,
          content_type: input.arguments.content_type,
          byte_size: input.arguments.byte_size
        )
        |> case do
          {:ok, %{blob: blob, url: url, method: method} = info} ->
            {:ok,
             %{
               blob_id: blob.id,
               url: url,
               method: to_string(method),
               headers: Map.get(info, :headers, %{})
             }}

          {:error, error} ->
            {:error, error}
        end
      end
    end
  end

  json_api do
    routes do
      base "/posts"

      index :read
      get :read
      post :create
      post :prepare_cover_image_upload, route: "/prepare_cover_image_upload"
    end
  end
end
```

The client flow:

1. `POST /posts/prepare_cover_image_upload` with `{"filename": "photo.jpg"}` — returns `{"blob_id": "...", "url": "https://...", "method": "PUT", "headers": {}}`
2. `PUT` the file directly to the presigned storage URL with any returned headers
3. `POST /posts` with `{"title": "My Post", "cover_image_blob_id": "..."}` — creates the post with the image attached

## AshGraphql

Same approach — the create mutation already accepts `cover_image_blob_id`, and a generic action mutation handles prepare:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    extensions: [AshStorage, AshGraphql]

  graphql do
    type :post

    queries do
      get :get_post, :read
      list :list_posts, :read
    end

    mutations do
      create :create_post, :create

      # Prepare direct upload
      action :prepare_cover_image_upload, :prepare_cover_image_upload
    end
  end

  # ...same actions as the JSON:API example above
end
```

```graphql
# 1. Prepare
mutation {
  prepareCoverImageUpload(input: {
    filename: "photo.jpg"
    contentType: "image/jpeg"
  }) {
    result {
      blobId
      url
      method
      headers
    }
  }
}

# 2. Upload directly to the presigned URL (outside GraphQL)

# 3. Create with blob attached
mutation {
  createPost(input: {
    title: "My Post"
    coverImageBlobId: "blob-uuid"
  }) {
    result {
      id
      coverImageUrl
    }
  }
}
```
