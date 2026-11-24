defmodule AshStorage.BlobResource do
  @moduledoc """
  A Spark extension for configuring a blob resource.

  Apply this extension to a resource that will store blob (file) metadata.
  The transformer will add the required attributes and actions.

  ## Usage

      defmodule MyApp.Storage.Blob do
        use Ash.Resource,
          domain: MyApp.Storage,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStorage.BlobResource]

        postgres do
          table "storage_blobs"
          repo MyApp.Repo
        end
      end

  The following attributes are added automatically:
  - `key` (string, required) - unique storage key
  - `filename` (string, required)
  - `content_type` (string)
  - `byte_size` (integer) - file size in bytes (nil for pending direct uploads)
  - `checksum` (string) - base64-encoded MD5 (nil for pending direct uploads)
  - `service_name` (atom, required)
  - `service_opts` (keyword, default `[]`) - persisted service options for async operations
  - `metadata` (map, default `%{}`)
  - `pending_purge` (boolean, default `false`) - whether this blob is awaiting async deletion

  The following actions are added:
  - `:create` (create) - accepts all blob attributes
  - `:read` (read)
  - `:destroy` (destroy)
  - `:update_metadata` (update) - accepts only `:metadata`
  - `:mark_for_purge` (update) - sets `pending_purge` to `true`
  - `:complete_analysis` (update) - records one analyzer's outcome: its `status`,
    the metadata it found (`metadata_to_merge`) and, when it failed, the reason
    as text (`error`)
  - `:purge_blob` (destroy) - destroys the blob's variants and then the record, and
    deletes their files from storage

  ## AshOban integration

  To enable async file purging, add `AshOban` to your blob resource's extensions
  and define a trigger that targets the `:purge_blob` action:

      defmodule MyApp.Storage.Blob do
        use Ash.Resource,
          extensions: [AshStorage.BlobResource, AshOban]

        oban do
          triggers do
            trigger :purge_blob do
              action :purge_blob
              where expr(pending_purge == true)
              scheduler_cron "* * * * *"
              max_attempts 3
            end
          end
        end
      end

  When AshOban is detected on the blob resource, dependent attachment purging
  on record destroy will mark blobs as `pending_purge: true` instead of
  deleting files synchronously. The AshOban trigger then picks them up and
  runs the `:purge_blob` action, which removes the blob's variants first and then
  the blob, with their files.
  """

  @blob %Spark.Dsl.Section{
    name: :blob,
    describe: "Configuration for the blob resource.",
    schema: []
  }

  use Spark.Dsl.Extension,
    sections: [@blob],
    transformers: [AshStorage.BlobResource.Transformers.SetupBlob]
end
