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
  - `byte_size` (integer, required)
  - `checksum` (string, required) - base64-encoded MD5
  - `service_name` (atom, required)
  - `metadata` (map, default `%{}`)

  The following actions are added:
  - `:create` (create) - accepts all blob attributes
  - `:read` (read)
  - `:destroy` (destroy)
  - `:update_metadata` (update) - accepts only `:metadata`
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
