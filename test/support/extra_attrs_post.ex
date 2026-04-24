defmodule AshStorage.Test.ExtraAttrsPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  ets do
    private? true
  end

  storage do
    service({AshStorage.Test.ExtraAttrsService, []})
    blob_resource(AshStorage.Test.Blob)
    attachment_resource(AshStorage.Test.PolymorphicAttachment)

    has_one_attached(:cover_image)

    has_one_attached :document do
      variant(:eager_uppercase, AshStorage.Test.UppercaseVariant, generate: :eager)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    create :create_with_image do
      accept [:title]
      argument :cover_image, :file, allow_nil?: true

      change {AshStorage.Changes.AttachFile, argument: :cover_image, attachment: :cover_image}
    end

    update :update_cover_image do
      argument :cover_image, :file, allow_nil?: true

      change {AshStorage.Changes.AttachFile, argument: :cover_image, attachment: :cover_image}
    end
  end
end
