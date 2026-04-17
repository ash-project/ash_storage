defmodule AshStorage.Test.IntegerAttachment do
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
    belongs_to_resource(:post, AshStorage.Test.IntegerPost, attribute_type: :integer)
  end

  attributes do
    uuid_primary_key :id
  end
end
