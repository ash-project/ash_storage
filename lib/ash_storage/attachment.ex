defmodule AshStorage.Attachment do
  @moduledoc """
  An Ash resource representing the association between an application record and a blob.

  Attachments connect domain models to their associated files. They support both
  single attachments (one-to-one) and multiple attachments (one-to-many).

  ## Attributes

  - `name` - The name of the attachment (e.g., "avatar", "documents")
  - `record_type` - The type of the associated record
  - `record_id` - The ID of the associated record
  - `blob_id` - Reference to the associated blob
  """

  use Ash.Resource,
    domain: nil,
    data_layer: :embedded

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
    end

    attribute :record_type, :string do
      allow_nil? false
    end

    attribute :record_id, :string do
      allow_nil? false
    end

    attribute :blob_id, :uuid do
      allow_nil? false
    end

    timestamps()
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :record_type, :record_id, :blob_id]
    end
  end
end
