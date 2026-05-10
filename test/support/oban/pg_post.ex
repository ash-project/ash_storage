defmodule AshStorage.Test.PgPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.PgDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStorage]

  postgres do
    table "posts"
    repo(AshStorage.TestRepo)
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.PgBlob)
    attachment_resource(AshStorage.Test.PgAttachment)

    has_one_attached :cover_image do
      variant(:eager_upper, AshStorage.Test.UppercaseVariant, generate: :eager)
      variant(:oban_upper, AshStorage.Test.UppercaseVariant, generate: :oban)
      variant(:oban_reverse, AshStorage.Test.ReverseVariant, generate: :oban)

      variant(:oban_grouped_a, {AshStorage.Test.UppercaseVariant, suffix: ":a"},
        generate: :oban,
        group: :fast
      )

      variant(:oban_grouped_b, {AshStorage.Test.UppercaseVariant, suffix: ":b"},
        generate: :oban,
        group: :fast
      )

      variant(:oban_later, AshStorage.Test.ReverseVariant, generate: :oban, order: 1)

      variant(:oban_extra_late, AshStorage.Test.UppercaseVariant, generate: :oban, order: 1)

      variant(:oban_slow_x, {AshStorage.Test.UppercaseVariant, suffix: ":x"},
        generate: :oban,
        group: :slow,
        order: 1
      )

      variant(:oban_slow_y, {AshStorage.Test.UppercaseVariant, suffix: ":y"},
        generate: :oban,
        group: :slow,
        order: 1
      )
    end

    has_many_attached(:documents, dependent: :detach)
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]
  end
end
