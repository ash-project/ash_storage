defmodule AshStorage.Test.Blob do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage.BlobResource]

  ets do
    private? true
  end

  blob do
  end

  attributes do
    uuid_primary_key :id
  end
end
