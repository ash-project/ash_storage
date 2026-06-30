defmodule AshStorage.Test.Tenant do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id, writable?: true
  end

  defimpl Ash.ToTenant do
    def to_tenant(tenant, _resource), do: tenant.id
  end
end
