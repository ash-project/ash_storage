defmodule AshStorage.OperationsTest do
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

  describe "attach/4" do
    test "uploads file and creates blob + attachment" do
      post = create_post!()

      assert {:ok, %{blob: blob, attachment: attachment}} =
               Operations.attach(post, :cover_image, "hello world",
                 filename: "hello.txt",
                 content_type: "text/plain"
               )

      assert blob.filename == "hello.txt"
      assert blob.content_type == "text/plain"
      assert blob.byte_size == 11
      assert blob.checksum == Base.encode64(:crypto.hash(:md5, "hello world"))
      assert blob.service_name == AshStorage.Service.Test

      assert attachment.name == "cover_image"
      assert attachment.blob_id == blob.id

      # File is in the service
      assert AshStorage.Service.Test.exists?(blob.key)
      assert {:ok, "hello world"} = AshStorage.Service.Test.download(blob.key, [])
    end

    test "replaces existing has_one_attached" do
      post = create_post!()

      {:ok, %{blob: old_blob}} =
        Operations.attach(post, :cover_image, "old file",
          filename: "old.txt",
          content_type: "text/plain"
        )

      {:ok, %{blob: new_blob}} =
        Operations.attach(post, :cover_image, "new file",
          filename: "new.txt",
          content_type: "text/plain"
        )

      # Old file is purged
      refute AshStorage.Service.Test.exists?(old_blob.key)
      # New file exists
      assert AshStorage.Service.Test.exists?(new_blob.key)
      assert {:ok, "new file"} = AshStorage.Service.Test.download(new_blob.key, [])
    end

    test "appends to has_many_attached" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc one",
          filename: "doc1.txt",
          content_type: "text/plain"
        )

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc two",
          filename: "doc2.txt",
          content_type: "text/plain"
        )

      # Both files exist
      assert AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)
    end

    test "stores custom metadata on blob" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "data",
          filename: "photo.jpg",
          metadata: %{"width" => 100, "height" => 200}
        )

      assert blob.metadata == %{"width" => 100, "height" => 200}
    end

    test "handles iodata input" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, ["hello", " ", "world"], filename: "hello.txt")

      assert blob.byte_size == 11
      assert {:ok, "hello world"} = AshStorage.Service.Test.download(blob.key, [])
    end

    test "returns error for unknown attachment name" do
      post = create_post!()

      assert :error = Operations.attach(post, :nonexistent, "data", filename: "f.txt")
    end
  end

  describe "detach/3" do
    test "detaches has_one_attached without deleting file" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "data", filename: "f.txt")

      assert {:ok, [_]} = Operations.detach(post, :cover_image)

      # File still exists in storage
      assert AshStorage.Service.Test.exists?(blob.key)
    end

    test "detaches specific blob from has_many_attached" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc1", filename: "d1.txt")

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc2", filename: "d2.txt")

      assert {:ok, [_]} = Operations.detach(post, :documents, blob_id: blob1.id)

      # Both files still in storage
      assert AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)
    end

    test "returns error when blob_id missing for has_many" do
      post = create_post!()
      Operations.attach(post, :documents, "doc", filename: "d.txt")

      assert {:error, :blob_id_required_for_has_many} = Operations.detach(post, :documents)
    end
  end

  describe "purge/3" do
    test "purges has_one_attached: removes attachment, blob, and file" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "data", filename: "f.txt")

      assert {:ok, [_]} = Operations.purge(post, :cover_image)

      refute AshStorage.Service.Test.exists?(blob.key)
    end

    test "purges specific blob from has_many_attached" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc1", filename: "d1.txt")

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc2", filename: "d2.txt")

      assert {:ok, [_]} = Operations.purge(post, :documents, blob_id: blob1.id)

      refute AshStorage.Service.Test.exists?(blob1.key)
      assert AshStorage.Service.Test.exists?(blob2.key)
    end

    test "purges all has_many_attached with :all option" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.attach(post, :documents, "doc1", filename: "d1.txt")

      {:ok, %{blob: blob2}} =
        Operations.attach(post, :documents, "doc2", filename: "d2.txt")

      assert {:ok, purged} = Operations.purge(post, :documents, all: true)
      assert length(purged) == 2

      refute AshStorage.Service.Test.exists?(blob1.key)
      refute AshStorage.Service.Test.exists?(blob2.key)
    end

    test "returns error when blob_id missing for has_many" do
      post = create_post!()
      Operations.attach(post, :documents, "doc", filename: "d.txt")

      assert {:error, :blob_id_required_for_has_many} = Operations.purge(post, :documents)
    end
  end
end
