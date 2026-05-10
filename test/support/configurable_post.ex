defmodule AshStorage.Test.ConfigurablePost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage],
    otp_app: :ash_storage

  ets do
    private? true
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.Blob)
    attachment_resource(AshStorage.Test.PolymorphicAttachment)

    has_one_attached(:avatar)

    has_one_attached(:mirrored_avatar,
      service:
        {AshStorage.Service.Test,
         [
           mirrors: [
             {AshStorage.Service.Test, name: :mirror_integration_primary},
             {AshStorage.Service.Test, name: :mirror_integration_secondary}
           ]
         ]}
    )

    has_one_attached(:legacy_mirror_avatar,
      service:
        {AshStorage.Service.Mirror,
         services: [
           {AshStorage.Service.Test, []},
           {AshStorage.Service.Test, name: :legacy_mirror_a},
           {AshStorage.Service.Test, name: :legacy_mirror_b}
         ]}
    )

    has_many_attached(:mirrored_documents,
      service:
        {AshStorage.Service.Test,
         [
           mirrors: [
             {AshStorage.Service.Test, name: :documents_mirror_a},
             {AshStorage.Service.Test, name: :documents_mirror_b}
           ]
         ]}
    )
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    update :attach_avatar_blob do
      require_atomic? false
      argument :avatar_blob_id, :uuid, allow_nil?: true

      change {AshStorage.Changes.AttachBlob, argument: :avatar_blob_id, attachment: :avatar}
    end
  end
end
