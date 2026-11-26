defmodule AshStorage.Test.FailOnMarkerVariant do
  @moduledoc false
  @behaviour AshStorage.Variant

  @impl true
  def accept?("text/" <> _), do: true
  def accept?(_), do: false

  @impl true
  def transform(source_path, dest_path, _opts) do
    content = File.read!(source_path)

    if String.contains?(content, "FAIL") do
      {:error, :transform_failed}
    else
      File.write!(dest_path, content)
      {:ok, %{}}
    end
  end
end

defmodule AshStorage.Test.MatrixPost do
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
    attachment_resource(AshStorage.Test.PolymorphicAttachment)

    has_one_attached :doc do
      analyzer(AshStorage.Test.TestAnalyzer, write_attributes: [line_count: :lines])
      analyzer(AshStorage.Test.FailingAnalyzer)
      variant(:upper, AshStorage.Test.UppercaseVariant, generate: :eager)
    end

    has_many_attached :files do
      variant(:upper, AshStorage.Test.UppercaseVariant, generate: :eager)
    end

    has_one_attached :fragile do
      variant(:checked, AshStorage.Test.FailOnMarkerVariant, generate: :eager)
    end

    has_one_attached(:plain)
  end

  attributes do
    uuid_primary_key :id
    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :lines, :integer, public?: true
  end

  identities do
    identity :unique_slug, [:slug], pre_check_with: AshStorage.Test.Domain
  end

  actions do
    defaults [:read, :destroy, create: [:slug], update: [:slug]]

    create :create_with_doc do
      accept [:slug]
      argument :doc, :file, allow_nil?: true

      change attach_file(:doc)
    end

    create :upsert_with_doc do
      accept [:slug]
      upsert? true
      upsert_identity :unique_slug
      argument :doc, :file, allow_nil?: true

      change attach_file(:doc)
    end

    for name <- [:doc, :files, :fragile, :plain] do
      update :"update_#{name}" do
        require_atomic? false
        argument name, :file, allow_nil?: true

        change attach_file(name)
      end
    end

    create :create_with_doc_blob do
      accept [:slug]
      argument :doc_blob_id, :uuid, allow_nil?: true

      change attach_blob(:doc, argument: :doc_blob_id)
    end

    create :upsert_with_doc_blob do
      accept [:slug]
      upsert? true
      upsert_identity :unique_slug
      argument :doc_blob_id, :uuid, allow_nil?: true

      change attach_blob(:doc, argument: :doc_blob_id)
    end

    for name <- [:doc, :files, :fragile, :plain] do
      update :"update_#{name}_blob" do
        require_atomic? false
        argument :"#{name}_blob_id", :uuid, allow_nil?: true

        change attach_blob(name, argument: :"#{name}_blob_id")
      end
    end
  end
end
