defmodule AshStorage.AttachmentResource do
  @moduledoc """
  A Spark extension for configuring an attachment resource.

  Apply this extension to a resource that will store attachment records
  (the join between your domain records and blobs).

  ## Usage

      defmodule MyApp.Storage.Attachment do
        use Ash.Resource,
          domain: MyApp.Storage,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStorage.AttachmentResource]

        postgres do
          table "storage_attachments"
          repo MyApp.Repo
        end

        attachment do
          blob_resource MyApp.Storage.Blob
        end
      end

  The following attributes are added automatically:
  - `name` (string, required) - attachment name (e.g. "avatar")
  - `record_type` (string, required) - the type of the owning record
  - `record_id` (string, required) - the ID of the owning record

  The following relationships are added:
  - `blob` (belongs_to) - reference to the blob resource

  The following actions are added:
  - `:create` (create)
  - `:read` (read)
  - `:destroy` (destroy)
  """

  @attachment %Spark.Dsl.Section{
    name: :attachment,
    describe: "Configuration for the attachment resource.",
    schema: [
      blob_resource: [
        type: :module,
        required: true,
        doc: "The blob resource module to reference."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@attachment],
    transformers: [AshStorage.AttachmentResource.Transformers.SetupAttachment]
end
