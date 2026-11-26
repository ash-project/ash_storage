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
    end

    has_many_attached(:documents, dependent: :detach)

    has_one_attached :report do
      analyzer(AshStorage.Test.TestAnalyzer, analyze: :oban)
      variant(:eager_upper, AshStorage.Test.UppercaseVariant, generate: :eager)
      variant(:oban_upper, AshStorage.Test.UppercaseVariant, generate: :oban)
    end

    has_one_attached :fragile do
      variant(:checked, AshStorage.Test.FailOnMarkerVariant, generate: :eager)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]

    for name <- [:cover_image, :report, :fragile] do
      update :"update_#{name}" do
        require_atomic? false
        argument name, :file, allow_nil?: true

        change attach_file(name)
      end

      update :"update_#{name}_blob" do
        require_atomic? false
        argument :"#{name}_blob_id", :uuid, allow_nil?: true

        change attach_blob(name, argument: :"#{name}_blob_id")
      end
    end
  end
end
