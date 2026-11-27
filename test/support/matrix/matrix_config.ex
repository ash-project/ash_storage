defmodule AshStorage.Test.Matrix.Context do
  @moduledoc false
  use AshStorage.Test.MatrixResources, multitenancy: :context
end

defmodule AshStorage.Test.Matrix.Attribute do
  @moduledoc false
  use AshStorage.Test.MatrixResources, multitenancy: :attribute
end

defmodule AshStorage.Test.Matrix.Actor do
  @moduledoc false
  use AshStorage.Test.MatrixResources, policies: :actor
end

defmodule AshStorage.Test.Matrix.Deny do
  @moduledoc false
  use AshStorage.Test.MatrixResources, policies: :deny
end

defmodule AshStorage.Test.MatrixConfig do
  @moduledoc false
  # The resource configurations the attach matrix runs under. Each is a map:
  #
  #   * `:post`, `:blob`, `:attachment` - the three resources
  #   * `:caller` - the options the acting caller passes
  #   * `:inspect` - the options assertions read with: the caller's tenant and
  #     `authorize?: false`, since they check the library's bookkeeping
  #   * `:gaps` - cells that fail under this configuration only, with the issue
  #     that explains them

  alias AshStorage.Test.Matrix

  def names, do: [:plain, :context, :attribute, :actor, :deny]

  def build(:plain) do
    %{
      name: :plain,
      post: AshStorage.Test.MatrixPost,
      blob: AshStorage.Test.Blob,
      attachment: AshStorage.Test.PolymorphicAttachment,
      caller: [],
      inspect: [authorize?: false],
      gaps: %{}
    }
  end

  def build(:context) do
    tenant = Ash.UUID.generate()
    resources(Matrix.Context, :context, [tenant: tenant], %{})
  end

  # A struct tenant, which reaches the data layer through `Ash.ToTenant`
  def build(:attribute) do
    tenant = %AshStorage.Test.Tenant{id: Ash.UUID.generate()}
    resources(Matrix.Attribute, :attribute, [tenant: tenant], %{})
  end

  def build(:actor) do
    resources(Matrix.Actor, :actor, [actor: %{id: "actor"}], %{})
  end

  # Blob and attachment allow nothing but the library's own calls
  def build(:deny) do
    resources(Matrix.Deny, :deny, [actor: %{id: "actor"}], %{})
  end

  defp resources(module, name, caller, gaps) do
    %{
      name: name,
      post: Module.concat(module, Post),
      blob: Module.concat(module, Blob),
      attachment: Module.concat(module, Attachment),
      caller: caller,
      inspect: Keyword.take(caller, [:tenant]) ++ [authorize?: false],
      gaps: gaps
    }
  end
end
