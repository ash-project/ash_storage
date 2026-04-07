# Variants

Variants transform uploaded files into new files — image thumbnails, format conversions, PDF previews, video thumbnails, etc. Each variant produces a new blob record linked back to the source blob.

## Defining a variant

Implement the `AshStorage.Variant` behaviour:

```elixir
defmodule MyApp.Thumbnail do
  @behaviour AshStorage.Variant

  @impl true
  def accept?(content_type), do: String.starts_with?(content_type, "image/")

  @impl true
  def transform(source_path, dest_path, opts) do
    width = Keyword.get(opts, :width, 200)
    height = Keyword.get(opts, :height, 200)
    # Use any image library — this example uses the `image` package
    source_path
    |> Image.open!()
    |> Image.thumbnail!("#{width}x#{height}", crop: :center)
    |> Image.write!(dest_path)
    {:ok, %{content_type: "image/webp"}}
  end
end
```

- `accept?/1` receives the source blob's content type. Return `false` to skip this variant for incompatible files.
- `transform/3` receives the source file path, the destination path to write to, and any opts from the DSL. Return `{:ok, metadata}` or `{:error, reason}`.

The metadata map returned from `transform/3` can include:

- `:content_type` — the MIME type of the output (defaults to the source blob's content type)
- `:filename` — override the variant blob's filename (defaults to `"variant_name_original_filename"`)
- Any other keys are stored in the variant blob's `metadata` map.

## Adding variants to attachments

Declare variants inside `has_one_attached` or `has_many_attached` blocks:

```elixir
storage do
  has_one_attached :cover_image do
    variant :thumbnail, {MyApp.Thumbnail, width: 200, height: 200}
    variant :hero, {MyApp.Thumbnail, width: 1200, height: 630, format: :jpg}
  end
end
```

This automatically adds URL calculations to the resource:

- `:cover_image_thumbnail_url`
- `:cover_image_hero_url`

For `has_many_attached`, the calculations return arrays:

- `:photos_thumbnail_urls`

## Generation modes

Each variant has a `generate` option controlling when the transformation runs:

### On-demand (default)

```elixir
variant :thumbnail, MyApp.Thumbnail
```

The variant is generated the first time its URL calculation is loaded. The request blocks while the transformation runs. On subsequent loads, the existing variant blob is found and returned without regeneration.

### Eager

```elixir
variant :thumbnail, MyApp.Thumbnail, generate: :eager
```

The variant is generated synchronously during the attach operation. The source file data is downloaded from storage, transformed, and the result is uploaded — all before the attach response is returned.

### Oban (background)

```elixir
variant :thumbnail, MyApp.Thumbnail, generate: :oban
```

The variant is queued for background generation via AshOban. See [Oban setup](#oban-setup) below.

## Loading variant URLs

```elixir
post = Ash.load!(post, [:cover_image_thumbnail_url, :cover_image_hero_url])
post.cover_image_thumbnail_url
#=> "http://localhost:4000/storage/a81bf21e..."
```

For on-demand variants, the first load triggers generation. If the source blob's content type is not accepted by the variant, the URL returns `nil`.

## How variant blobs are stored

Variant blobs are stored in the same blob resource as source blobs, with three additional fields:

- `variant_of_blob_id` — references the source blob
- `variant_name` — e.g. `"thumbnail"`
- `variant_digest` — a hash of `{module, opts}` for cache invalidation

The blob resource has a self-referential `:variants` relationship, so you can load them:

```elixir
post = Ash.load!(post, cover_image: [blob: :variants])
post.cover_image.blob.variants
#=> [%MyApp.StorageBlob{variant_name: "thumbnail", ...}]
```

## Cache invalidation via digest

Each variant definition produces a digest from its module and opts. If you change the opts (e.g. resize from 200x200 to 300x300), the digest changes. On-demand variants with stale digests are regenerated automatically — the URL calculation looks for a matching `variant_digest` and generates a new one if not found.

Old variant blobs with outdated digests are not automatically cleaned up. You can query for orphaned variants and delete them periodically if needed.

## Oban setup

To use `generate: :oban`, add AshOban to your blob resource with a `:run_pending_variants` trigger:

```elixir
defmodule MyApp.StorageBlob do
  use Ash.Resource,
    extensions: [AshStorage.BlobResource, AshOban]

  blob do
  end

  oban do
    triggers do
      trigger :run_pending_variants do
        action :run_pending_variants
        read_action :read

        where expr(
          not is_nil(fragment("metadata->>'__pending_variants__'"))
        )

        scheduler_cron("* * * * *")
        max_attempts(3)
      end
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
```

When a file is attached with oban variants, the pending variant definitions are stored in `blob.metadata["__pending_variants__"]`. The Oban trigger picks up blobs with pending variants, downloads the source, runs each transformation, uploads the results, and updates the status to `"complete"`.

If you use `generate: :oban` without this trigger configured, a compile-time verifier will raise an error.

## Mixing generation modes

You can combine modes on the same attachment:

```elixir
has_one_attached :photo do
  variant :thumbnail, {MyApp.Thumbnail, width: 100}, generate: :eager
  variant :hero, {MyApp.Thumbnail, width: 1200}, generate: :oban
  variant :square, {MyApp.Thumbnail, width: 500, crop: :center}  # on-demand
end
```

Eager variants are available immediately after attach. Oban variants are generated in the background. On-demand variants are generated when first requested via URL calculation.
