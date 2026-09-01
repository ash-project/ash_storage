defmodule AshStorage.Test.LayeredPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  ets do
    private? true
  end

  storage do
    service({AshStorage.Service.Test, []})

    layer({AshStorage.Test.StaticSuffixLayer, suffix: "-resource"})

    blob_resource(AshStorage.Test.Blob)
    attachment_resource(AshStorage.Test.PolymorphicAttachment)

    has_one_attached :cover_image do
      layer({AshStorage.Test.StaticSuffixLayer, suffix: "-cover"})
    end

    has_one_attached :encrypted_cover do
      layer(
        {AshStorage.Layer.Encryption,
         proxy_base_url: "/storage",
         key_manager: {AshStorage.Encryption.KeyManagers.Cloak, vault: AshStorage.Test.Vault}},
        metadata_key: "encrypted-cover"
      )
    end

    has_many_attached :documents do
      dependent(:detach)
      layer({AshStorage.Test.StaticSuffixLayer, suffix: "-document"})
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]
  end
end
