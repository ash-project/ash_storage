defmodule AshStorage.Test.KeyRulesPost do
  @moduledoc false
  # Attachments whose `path` functions return keys that break the rules in
  # `AshStorage.Key`, next to ones that follow them.
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
    attachment_resource(AshStorage.Test.PolymorphicAttachment)

    has_one_attached(:plain)

    has_one_attached :valid do
      path fn _ctx, _changeset -> "covers/#{AshStorage.generate_key()}" end
    end

    has_one_attached :spaced do
      path fn _ctx, _changeset -> "my photos/#{AshStorage.generate_key()}" end
    end

    has_one_attached :parent do
      path fn _ctx, _changeset -> "../../etc/#{AshStorage.generate_key()}" end
    end

    has_one_attached :absolute do
      path fn _ctx, _changeset -> "/etc/passwd" end
    end

    has_one_attached :empty do
      path fn _ctx, _changeset -> "" end
    end

    has_one_attached :not_a_string do
      path fn _ctx, _changeset -> nil end
    end

    has_one_attached :document do
      variant(:uppercase, AshStorage.Test.UppercaseVariant)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    create :create_with_file do
      accept [:title]
      argument :file, :file, allow_nil?: false

      change attach_file(:parent, argument: :file)
    end
  end
end
