defmodule AshStorage.PrimaryKeyTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule SlugPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.PrimaryKeyTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)

      has_one_attached(:cover)
    end

    attributes do
      attribute :slug, :string, primary_key?: true, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy, create: [:slug]]
    end
  end

  defmodule KeyedPost do
    @moduledoc false
    # A composite key is fine for a resource without attachments
    use Ash.Resource,
      domain: AshStorage.PrimaryKeyTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)
    end

    attributes do
      uuid_primary_key :id
      attribute :org, :string, primary_key?: true, allow_nil?: false
    end
  end

  setup do
    Store.reset!()
    :ok
  end

  defp post!(slug), do: Ash.create!(SlugPost, %{slug: slug})

  describe "a host whose primary key is not :id" do
    test "attaches, loads, replaces and purges by its key" do
      post = post!("first-post")

      assert {:ok, %{blob: old, attachment: attachment}} =
               Operations.attach(post, :cover, "old", filename: "old.txt")

      assert attachment.record_id == "first-post"

      loaded = Ash.load!(post, [:cover_url, cover: :blob])
      assert loaded.cover.blob.id == old.id
      assert loaded.cover_url =~ old.key

      {:ok, %{blob: new}} = Operations.attach(post, :cover, "new", filename: "new.txt")
      assert Ash.load!(post, cover: :blob).cover.blob.id == new.id
      refute Store.exists?(old.key)

      assert {:ok, [_]} = Operations.purge(post, :cover)
      assert Ash.load!(post, :cover).cover == nil
      refute Store.exists?(new.key)
    end

    test "a destroy purges its file" do
      post = post!("destroyed")
      {:ok, %{blob: blob}} = Operations.attach(post, :cover, "gone", filename: "gone.txt")

      Ash.destroy!(post)

      refute Store.exists?(blob.key)
    end

    test "each record loads its own file" do
      one = post!("one")
      two = post!("two")
      {:ok, %{blob: blob_one}} = Operations.attach(one, :cover, "1", filename: "1.txt")
      {:ok, %{blob: blob_two}} = Operations.attach(two, :cover, "2", filename: "2.txt")

      assert Ash.load!(one, cover: :blob).cover.blob.id == blob_one.id
      assert Ash.load!(two, cover: :blob).cover.blob.id == blob_two.id
    end
  end

  test "a host with attachments and a composite primary key does not compile" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        defmodule CompositePost do
          @moduledoc false
          use Ash.Resource,
            domain: AshStorage.PrimaryKeyTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshStorage]

          storage do
            service({AshStorage.Service.Test, []})
            blob_resource(AshStorage.Test.Blob)
            attachment_resource(AshStorage.Test.PolymorphicAttachment)

            has_one_attached(:cover)
          end

          attributes do
            uuid_primary_key :id
            attribute :org, :string, primary_key?: true, allow_nil?: false
          end
        end
      end

    assert error.message =~ "primary key"
    assert error.message =~ "CompositePost"
    assert error.message =~ ":id"
    assert error.message =~ ":org"
  end

  test "a resource with a composite primary key and no attachments compiles" do
    assert [:id, :org] = Ash.Resource.Info.primary_key(KeyedPost)
  end
end
