defmodule AshStorage.AttachmentResource do
  @moduledoc """
  A Spark extension for configuring an attachment resource.

  Apply this extension to a resource that will store attachment records
  (the join between your domain records and blobs).

  ## Usage

  With proper foreign keys (recommended):

      defmodule MyApp.Storage.PostAttachment do
        use Ash.Resource,
          domain: MyApp.Storage,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshStorage.AttachmentResource]

        postgres do
          table "post_attachments"
          repo MyApp.Repo
        end

        attachment do
          blob_resource MyApp.Storage.Blob
          belongs_to_resource :post, MyApp.Post
        end
      end

  Without foreign keys (polymorphic, shared table):

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

  ## Attributes

  Always added:
  - `name` (string, required) - attachment name (e.g. "avatar")

  When no `belongs_to_resource` is declared (polymorphic mode):
  - `record_type` (string, required) - the type of the owning record
  - `record_id` (string, required) - the ID of the owning record

  ## Relationships

  Always added:
  - `blob` (belongs_to) - reference to the blob resource

  Per `belongs_to_resource` declaration:
  - A `belongs_to` relationship to the specified resource

  ## Actions

  - `:create` (create)
  - `:read` (read)
  - `:destroy` (destroy)
  """

  defmodule BelongsToResource do
    @moduledoc "Represents a belongs_to_resource declaration on an attachment resource."
    defstruct [:name, :resource, :attribute_type, :__spark_metadata__]
  end

  @belongs_to_resource %Spark.Dsl.Entity{
    name: :belongs_to_resource,
    args: [:name, :resource],
    describe:
      "Declares a belongs_to relationship to a parent resource, creating a proper foreign key.",
    examples: [
      "belongs_to_resource :post, MyApp.Post",
      "belongs_to_resource :post, MyApp.Post, attribute_type: :integer"
    ],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the relationship."
      ],
      resource: [
        type: :module,
        required: true,
        doc: "The parent resource module."
      ],
      attribute_type: [
        type: :any,
        required: false,
        doc:
          "The type of the generated FK attribute. Defaults to `:uuid`. Set to `:integer` if the parent resource uses `integer_primary_key`."
      ]
    ],
    target: BelongsToResource
  }

  @attachment %Spark.Dsl.Section{
    name: :attachment,
    describe: "Configuration for the attachment resource.",
    schema: [
      blob_resource: [
        type: :module,
        required: true,
        doc: "The blob resource module to reference."
      ]
    ],
    entities: [@belongs_to_resource]
  }

  use Spark.Dsl.Extension,
    sections: [@attachment],
    transformers: [AshStorage.AttachmentResource.Transformers.SetupAttachment]
end
