# File Arguments

Instead of using `AshStorage.Operations.attach/4` separately, you can add file arguments directly to your create and update actions. Users pass an `Ash.Type.File` value and the file is attached automatically as part of the action.

## Basic setup

Add an argument and a change to your action:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    extensions: [AshStorage]

  storage do
    blob_resource MyApp.StorageBlob
    attachment_resource MyApp.StorageAttachment

    has_one_attached :cover_image
  end

  actions do
    create :create do
      accept [:title]
      argument :cover_image, Ash.Type.File, allow_nil?: true

      change {AshStorage.Changes.HandleFileArgument,
              argument: :cover_image, attachment: :cover_image}
    end

    update :update do
      argument :cover_image, Ash.Type.File, allow_nil?: true

      change {AshStorage.Changes.HandleFileArgument,
              argument: :cover_image, attachment: :cover_image}
    end
  end
end
```

Then use it:

```elixir
# From a Plug.Upload (e.g. in a Phoenix controller)
Post
|> Ash.Changeset.for_create(:create, %{
  title: "My Post",
  cover_image: upload  # %Plug.Upload{} works directly
})
|> Ash.create!()

# From a file path
Post
|> Ash.Changeset.for_create(:create, %{
  title: "My Post",
  cover_image: Ash.Type.File.from_path("/tmp/photo.jpg")
})
|> Ash.create!()
```

When the argument is `nil`, the change is skipped and no file is attached.

## How it works

`AshStorage.Changes.HandleFileArgument` runs in two phases:

**Before action:** Uploads the file to storage, creates the blob record, runs eager analyzers, and applies any `write_attributes` to the changeset via `force_change_attributes`. This means analyzer-derived attributes are set in the same database write as the parent record — no extra update query.

**After action:** Creates the attachment record linking the blob to the now-persisted parent record. For `has_one_attached` on update actions, replaces any existing attachment (purging the old file). Triggers oban analyzers if configured.

## Filename and content type

The change extracts filename and content type from the `Ash.Type.File` source when possible:

- `Plug.Upload` provides both `filename` and `content_type`
- File paths provide the filename via `Path.basename/1`
- `IO.device` sources provide neither

When the source doesn't provide a value, the defaults are `"upload"` for filename and `"application/octet-stream"` for content type.

> **Note:** Full filename/content_type extraction requires Ash version with the `Ash.Type.File.filename/1` and `Ash.Type.File.content_type/1` callbacks. On older Ash versions, the defaults are used. This is handled gracefully at runtime.

## Alternative: `AshStorage.Changes.AttachFile`

There is also a simpler `AttachFile` change that calls `AshStorage.Operations.attach/4` in an `after_action` hook:

```elixir
create :create do
  argument :cover_image, :file, allow_nil?: true

  change {AshStorage.Changes.AttachFile,
          argument: :cover_image, attachment: :cover_image}
end
```

The difference from `HandleFileArgument`:

| | `HandleFileArgument` | `AttachFile` |
|---|---|---|
| `write_attributes` | Supported (applied in before_action) | Not supported |
| Eager analyzers | Run in before_action, attributes set atomically | Run via `Operations.attach` after record is saved |
| Argument type | `Ash.Type.File` | `:file` |

Use `HandleFileArgument` when you need `write_attributes` or want the tightest integration. Use `AttachFile` for simpler cases.

## Direct uploads with `Operations.attach/4`

When you don't want to wire a file argument into an Ash action — typical in a Phoenix controller that handles the upload imperatively — call `AshStorage.Operations.attach/4` directly. The `io` argument accepts the same shapes as the file-argument path, including `%Plug.Upload{}`:

```elixir
def upload(conn, %{"id" => post_id, "image" => %Plug.Upload{} = upload}) do
  {:ok, post} = Ash.get(MyApp.Post, post_id, actor: conn.assigns.current_user)

  {:ok, %{blob: blob}} =
    AshStorage.Operations.attach(post, :images, upload,
      filename: upload.filename || "image",
      content_type: upload.content_type || "application/octet-stream",
      actor: conn.assigns.current_user
    )

  json(conn, %{blob_id: blob.id})
end
```

The `io` argument can be any of:

| Value | Source on disk? | Notes |
|---|---|---|
| `%Plug.Upload{}` | Yes (`upload.path`) | Read for you; pass the struct itself, not `upload.path`. |
| `%Ash.Type.File{}` | Yes | Same value you'd accept on a file argument. |
| `%File.Stream{}` | Yes | Collected into memory. |
| binary | No — in-memory | The *bytes* to store. Not a filesystem path. |
| iodata list | No — in-memory | Flattened to a binary. |

> **Gotcha:** the binary clause matches **any** binary, including a filesystem path string. If you pass `upload.path` (the path string) instead of `upload` (the struct), `attach/4` will happily upload the literal path as the blob body. Always pass the struct.

The `:filename` and `:content_type` options are forwarded to the configured service via the `Context` (see `AshStorage.Service.Context`) — for example, the bundled S3 service uses `:content_type` to set the `Content-Type` header on the PUT.
