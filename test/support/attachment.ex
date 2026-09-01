defmodule AshStorage.Test.Attachment do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage.AttachmentResource]

  ets do
    private? true
  end

  attachment do
    blob_resource(AshStorage.Test.Blob)
    belongs_to_resource(:post, AshStorage.Test.Post)
    belongs_to_resource(:analyzable_post, AshStorage.Test.AnalyzablePost)
    belongs_to_resource(:variant_post, AshStorage.Test.VariantPost)
    belongs_to_resource(:encrypted_variant_post, AshStorage.Test.EncryptedVariantPost)
  end

  attributes do
    uuid_primary_key :id
  end
end
