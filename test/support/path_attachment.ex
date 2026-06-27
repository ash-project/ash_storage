defmodule AshStorage.Test.PathAttachment do
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
    belongs_to_resource(:path_post, AshStorage.Test.PathPost)
    belongs_to_resource(:nested_path_post, AshStorage.Test.NestedPathPost)
  end

  attributes do
    uuid_primary_key :id
  end
end
