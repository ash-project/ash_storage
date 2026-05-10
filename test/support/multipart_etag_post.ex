defmodule AshStorage.Test.MultipartEtagPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  ets do
    private? true
  end

  storage do
    service({AshStorage.Test.MultipartEtagService, []})
    blob_resource(AshStorage.Test.Blob)
    attachment_resource(AshStorage.Test.PolymorphicAttachment)

    has_one_attached(:cover_image)
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    update :attach_blob do
      require_atomic? false
      argument :cover_image_blob_id, :uuid, allow_nil?: true

      change {AshStorage.Changes.AttachBlob,
              argument: :cover_image_blob_id, attachment: :cover_image}
    end
  end
end
