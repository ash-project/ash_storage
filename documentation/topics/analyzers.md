# Analyzers

Analyzers extract metadata from uploaded files — image dimensions, line counts, file hashes, etc. Results are stored on the blob's `analyzers` map and can optionally be written back to attributes on the parent record.

## Defining an analyzer

Implement the `AshStorage.Analyzer` behaviour:

```elixir
defmodule MyApp.ImageDimensions do
  @behaviour AshStorage.Analyzer

  @impl true
  def accept?("image/png"), do: true
  def accept?("image/jpeg"), do: true
  def accept?(_), do: false

  @impl true
  def analyze(path, _opts) do
    # path is a local file path to the uploaded content
    {:ok, %{"width" => 1920, "height" => 1080}}
  end
end
```

- `accept?/1` receives the blob's content type. Return `false` to skip analysis for that file.
- `analyze/2` receives the file path and any opts from the DSL. Return `{:ok, metadata_map}` or `{:error, reason}`.

## Adding analyzers to attachments

Declare analyzers inside `has_one_attached` or `has_many_attached` blocks:

```elixir
storage do
  has_one_attached :cover_image do
    analyzer MyApp.ImageDimensions
    analyzer {MyApp.FileInfo, include_exif: true}
  end
end
```

The `{Module, opts}` tuple form passes `opts` as the second argument to `analyze/2`.

By default, analyzers run eagerly — synchronously during the attach operation, before the response is returned. The file data is still in memory from the upload, so no download round-trip is needed.

## Reading analyzer results

Analyzer results are stored across two blob fields:

- `blob.analyzers` tracks the status of each analyzer
- `blob.metadata` holds the merged result data from all analyzers

```elixir
post = Ash.load!(post, cover_image: :blob)

post.cover_image.blob.analyzers
#=> %{
#   "MyApp.ImageDimensions" => %{"status" => "complete", "opts" => %{}}
# }

post.cover_image.blob.metadata
#=> %{"width" => 1920, "height" => 1080}
```

If multiple analyzers return overlapping keys, later results overwrite earlier ones in the metadata map.

## Writing results to parent attributes

Use `write_attributes` to map analyzer result keys to attributes on the parent record:

```elixir
storage do
  has_one_attached :cover_image do
    analyzer MyApp.ImageDimensions,
      write_attributes: [width: :image_width, height: :image_height]
  end
end

attributes do
  attribute :image_width, :integer, public?: true
  attribute :image_height, :integer, public?: true
end
```

When `ImageDimensions` returns `%{"width" => 1920, "height" => 1080}`, the values are written to `:image_width` and `:image_height` on the parent record as part of the same action — no extra update query.

For eager analyzers, this happens in a `before_action` hook via `force_change_attributes`. For oban analyzers, a separate update is performed when the background job completes.

## Background analysis with AshOban

For expensive analysis (video processing, large file scanning), run analyzers in the background:

```elixir
has_one_attached :video do
  analyzer MyApp.VideoDuration, analyze: :oban
end
```

This requires AshOban to be configured on your blob resource:

```elixir
defmodule MyApp.StorageBlob do
  use Ash.Resource,
    extensions: [AshStorage.BlobResource, AshOban]

  blob do
  end

  oban do
    triggers do
      trigger :run_pending_analyzers do
        action :run_pending_analyzers
        read_action :read

        where expr(
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_each(?) AS a WHERE a.value->>'status' = 'pending')",
            analyzers
          )
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

The `where` clause ensures only blobs with pending analyzers are picked up. When the trigger fires, the `:run_pending_analyzers` action downloads the file from storage and runs each pending analyzer.

If you use `analyze: :oban` without this trigger configured, a compile-time verifier will raise an error telling you what to add.

## Mixing eager and oban analyzers

You can combine both on the same attachment:

```elixir
has_one_attached :photo do
  analyzer MyApp.FileInfo                           # runs immediately
  analyzer MyApp.ImageDimensions, analyze: :oban    # runs in background
end
```

The eager analyzer runs during attach. The oban analyzer is queued and runs when Oban picks it up.
