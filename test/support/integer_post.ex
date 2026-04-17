defmodule AshStorage.Test.IntegerPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  actions do
    defaults [:read, :destroy, create: []]
  end

  attributes do
    integer_primary_key :id
  end
end
