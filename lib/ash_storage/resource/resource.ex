defmodule AshStorage.Resource do
  @moduledoc """
  An Ash extension for adding file attachments to a resource.

  ## Usage

      defmodule MyApp.Post do
        use Ash.Resource,
          extensions: [AshStorage.Resource]

        storage do
          has_one_attached :cover_image
          has_many_attached :documents
        end
      end

  ## Configuration

  The `service` option can be overridden per-environment using application config:

      config :my_app, MyApp.Post,
        storage: [service: {AshStorage.Service.Test, []}]
  """

  alias AshStorage.Resource.AttachmentDefinition

  @has_one_attached %Spark.Dsl.Entity{
    name: :has_one_attached,
    args: [:name],
    describe: "Declares a single file attachment on this resource.",
    examples: [
      "has_one_attached :avatar",
      "has_one_attached :cover_image, service: {AshStorage.Service.Disk, root: \"priv/storage\"}"
    ],
    schema: AttachmentDefinition.has_one_schema(),
    target: AttachmentDefinition,
    auto_set_fields: [type: :one]
  }

  @has_many_attached %Spark.Dsl.Entity{
    name: :has_many_attached,
    args: [:name],
    describe: "Declares a collection of file attachments on this resource.",
    examples: [
      "has_many_attached :documents",
      "has_many_attached :photos, dependent: :detach"
    ],
    schema: AttachmentDefinition.has_many_schema(),
    target: AttachmentDefinition,
    auto_set_fields: [type: :many]
  }

  @storage %Spark.Dsl.Section{
    name: :storage,
    describe: "Configure file storage and attachments for this resource.",
    schema: [
      service: [
        type: {:tuple, [:module, :keyword_list]},
        doc:
          "The default storage service for all attachments on this resource, as a `{module, opts}` tuple. Can be overridden per-attachment or via application config.",
        required: false
      ],
      blob_resource: [
        type: :module,
        required: true,
        doc: "The blob resource module (must use `AshStorage.BlobResource` extension)."
      ],
      attachment_resource: [
        type: :module,
        required: true,
        doc:
          "The attachment resource module (must use `AshStorage.AttachmentResource` extension)."
      ]
    ],
    entities: [
      @has_one_attached,
      @has_many_attached
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@storage]
end
