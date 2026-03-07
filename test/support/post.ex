defmodule AshStorage.Test.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage.Resource]

  ets do
    private? true
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.Blob)
    attachment_resource(AshStorage.Test.Attachment)

    has_one_attached(:cover_image)
    has_many_attached(:documents, dependent: :detach)
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

      change {AshStorage.Resource.Changes.AttachFile,
              argument: :cover_image, attachment: :cover_image}
    end

    update :update_cover_image do
      require_atomic? false
      argument :cover_image, :file, allow_nil?: true

      change {AshStorage.Resource.Changes.AttachFile,
              argument: :cover_image, attachment: :cover_image}
    end
  end
end
