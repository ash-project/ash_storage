defmodule AshStorage.VariantRecord do
  @moduledoc """
  An Ash resource tracking image variants when variant tracking is enabled.

  Variant records associate a transformed image blob with the original blob
  and the transformation parameters that were used.

  ## Attributes

  - `blob_id` - Reference to the original blob
  - `variation_digest` - Digest of the transformation parameters
  - `image_blob_id` - Reference to the variant's blob
  """

  use Ash.Resource,
    domain: nil,
    data_layer: :embedded

  attributes do
    uuid_primary_key :id

    attribute :blob_id, :uuid do
      allow_nil? false
    end

    attribute :variation_digest, :string do
      allow_nil? false
    end

    attribute :image_blob_id, :uuid do
      allow_nil? false
    end

    timestamps()
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:blob_id, :variation_digest, :image_blob_id]
    end
  end
end
