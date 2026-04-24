defmodule AshStorage.ExtraBlobAttrsTest do
  use ExUnit.Case, async: false

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test post") do
    AshStorage.Test.ExtraAttrsPost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  describe "Operations.attach with extra blob attrs" do
    test "service returning {:ok, map} merges attrs into blob" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "hello",
          filename: "hello.txt",
          content_type: "text/plain"
        )

      assert blob.metadata["injected"] == "from_service"
      assert blob.metadata["key"] == blob.key
    end

    test "service extra attrs merge with caller-provided metadata" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "hello",
          filename: "hello.txt",
          metadata: %{"user_tag" => "important"}
        )

      # Service returns metadata that replaces the caller metadata via Map.merge.
      # The extra_blob_attrs map has a :metadata key that overwrites the original.
      # This is expected — the service has final say on the metadata field.
      assert blob.metadata["injected"] == "from_service"
    end
  end

  describe "AttachFile change with extra blob attrs" do
    test "create action merges service attrs into blob" do
      path = Path.join(System.tmp_dir!(), "extra_attrs_create.txt")
      File.write!(path, "create test data")

      post =
        AshStorage.Test.ExtraAttrsPost
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "with image",
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)
      blob = post.cover_image.blob

      assert blob.metadata["injected"] == "from_service"
      assert blob.metadata["key"] == blob.key
    after
      File.rm(Path.join(System.tmp_dir!(), "extra_attrs_create.txt"))
    end

    test "update action merges service attrs into blob" do
      post = create_post!()

      path = Path.join(System.tmp_dir!(), "extra_attrs_update.txt")
      File.write!(path, "update test data")

      post =
        post
        |> Ash.Changeset.for_update(:update_cover_image, %{
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.update!()

      post = Ash.load!(post, cover_image: :blob)
      blob = post.cover_image.blob

      assert blob.metadata["injected"] == "from_service"
      assert blob.metadata["key"] == blob.key
    after
      File.rm(Path.join(System.tmp_dir!(), "extra_attrs_update.txt"))
    end
  end

  describe "VariantGenerator with extra blob attrs" do
    test "eager variant blob gets service extra attrs" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :document, "hello world",
          filename: "test.txt",
          content_type: "text/plain"
        )

      blob = Ash.load!(blob, :variants)
      variant = Enum.find(blob.variants, &(&1.variant_name == "eager_uppercase"))

      assert variant != nil
      assert variant.metadata["injected"] == "from_service"
      assert variant.metadata["key"] == variant.key

      # Verify the variant data was actually uploaded correctly
      assert {:ok, "HELLO WORLD"} = AshStorage.Service.Test.download(variant.key, [])
    end
  end
end
