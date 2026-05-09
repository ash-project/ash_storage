defmodule AshStorage.Test.UppercaseVariant do
  @moduledoc false
  @behaviour AshStorage.Variant

  @impl true
  def accept?("text/" <> _), do: true
  def accept?(_), do: false

  @impl true
  def transform(source_path, dest_path, opts) do
    content = File.read!(source_path)
    transformed = String.upcase(content)

    suffix = Keyword.get(opts, :suffix, "")
    transformed = transformed <> suffix

    File.write!(dest_path, transformed)
    {:ok, %{content_type: "text/plain"}}
  end
end

defmodule AshStorage.Test.RejectAllVariant do
  @moduledoc false
  @behaviour AshStorage.Variant

  @impl true
  def accept?(_), do: false

  @impl true
  def transform(_source, _dest, _opts), do: {:error, :not_implemented}
end

defmodule AshStorage.Test.FailingVariant do
  @moduledoc false
  @behaviour AshStorage.Variant

  @impl true
  def accept?(_), do: true

  @impl true
  def transform(_source, _dest, _opts), do: {:error, :transform_failed}
end

defmodule AshStorage.Test.ReverseVariant do
  @moduledoc false
  @behaviour AshStorage.Variant

  @impl true
  def accept?("text/" <> _), do: true
  def accept?(_), do: false

  @impl true
  def transform(source_path, dest_path, _opts) do
    content = File.read!(source_path)
    File.write!(dest_path, String.reverse(content))
    {:ok, %{content_type: "text/plain"}}
  end
end

defmodule AshStorage.Test.VariantPost do
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
    attachment_resource(AshStorage.Test.Attachment)

    has_one_attached :document do
      variant(:uppercase, AshStorage.Test.UppercaseVariant)
      variant(:eager_uppercase, AshStorage.Test.UppercaseVariant, generate: :eager)
      variant(:custom, {AshStorage.Test.UppercaseVariant, suffix: "!!!"}, generate: :eager)
    end

    has_one_attached :image do
      variant(:rejected, AshStorage.Test.RejectAllVariant, generate: :eager)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: []]
  end
end
