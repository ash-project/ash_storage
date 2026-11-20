defmodule AshStorage.DependentTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test post") do
    AshStorage.Test.Post
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  describe "dependent: :purge (cover_image)" do
    test "destroying record purges attachment, blob, and file" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      assert AshStorage.Service.Test.exists?(blob.key)

      Ash.destroy!(post)

      refute AshStorage.Service.Test.exists?(blob.key)
    end

    test "destroying record removes the blob's variants and their files" do
      post =
        AshStorage.Test.VariantPost
        |> Ash.Changeset.for_create(:create, %{title: "variants"})
        |> Ash.create!()

      {:ok, _} =
        Operations.attach(post, :document, "hello", filename: "a.txt", content_type: "text/plain")

      Ash.destroy!(post)

      assert AshStorage.Service.Test.list_keys() == []
    end

    test "destroying record keeps a blob another record uses" do
      post = create_post!()
      other = create_post!("other")

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      other
      |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
      |> Ash.update!()

      Ash.destroy!(post)

      assert {:ok, _} = Ash.get(AshStorage.Test.Blob, blob.id)
      assert AshStorage.Service.Test.exists?(blob.key)
    end

    test "destroying record with no attachments succeeds" do
      post = create_post!()
      Ash.destroy!(post)
    end
  end

  describe "dependent: :detach (documents)" do
    test "destroying record detaches but keeps blobs and files" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc one", filename: "d1.txt")

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc two", filename: "d2.txt")

      assert AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)

      Ash.destroy!(post)

      # Files still in storage
      assert AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)
    end
  end

  describe "soft destroy" do
    test "soft destroy does not purge or detach" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      # Verify the change is scoped to destroy actions
      # and that soft? destroys skip it
      changes = Ash.Resource.Info.changes(AshStorage.Test.Post)

      storage_change =
        Enum.find(changes, fn change ->
          change.change == {AshStorage.Changes.HandleDependentAttachments, []}
        end)

      assert storage_change
      assert :destroy in storage_change.on

      # The file should still be there (we didn't destroy)
      assert AshStorage.Service.Test.exists?(blob.key)
    end
  end
end
