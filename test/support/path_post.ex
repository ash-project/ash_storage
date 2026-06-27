defmodule AshStorage.Test.PathPost do
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
    blob_resource(AshStorage.Test.Blob)
    attachment_resource(AshStorage.Test.PathAttachment)

    has_one_attached(:avatar) do
      path fn _ctx, changeset ->
        actor = changeset.context[:private][:actor]
        org_id = actor && Map.get(actor, :org_id)
        "#{org_id}/#{AshStorage.generate_key()}"
      end
    end

    has_many_attached(:files) do
      path fn _ctx, changeset ->
        tenant = changeset.tenant || "default"
        "#{tenant}/#{AshStorage.generate_key()}"
      end
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
