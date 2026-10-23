defmodule AshStorage.DirectUploadTest do
  use ExUnit.Case, async: false

  require Ash.Query

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

  describe "prepare_direct_upload/3" do
    test "creates blob and returns upload info" do
      {:ok, result} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 12_345
        )

      assert result.blob.filename == "photo.jpg"
      assert result.blob.content_type == "image/jpeg"
      assert result.blob.byte_size == 12_345
      assert result.blob.service_name == AshStorage.Service.Test

      assert result.url =~ "http://test.local/storage/direct/"
      assert result.method == :put
    end

    test "generates a unique key for each upload" do
      {:ok, result1} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image, filename: "a.jpg")

      {:ok, result2} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image, filename: "b.jpg")

      refute result1.blob.key == result2.blob.key
    end

    test "stores metadata on blob" do
      {:ok, result} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "photo.jpg",
          metadata: %{"width" => 800, "height" => 600}
        )

      assert result.blob.metadata == %{"width" => 800, "height" => 600}
    end

    test "returns error for unknown attachment" do
      assert :error =
               Operations.prepare_direct_upload(AshStorage.Test.Post, :nonexistent,
                 filename: "f.txt"
               )
    end
  end

  describe "AttachBlob change on create" do
    test "attaches blob to new record" do
      {:ok, %{blob: blob}} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 100
        )

      # Simulate client uploading directly
      AshStorage.Service.Test.upload(blob.key, "direct data", AshStorage.Service.Context.new([]))

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_blob, %{
          title: "direct upload post",
          cover_image_blob_id: blob.id
        })
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image.blob.id == blob.id
      assert post.cover_image.blob.filename == "photo.jpg"
    end

    test "skips when blob_id is nil" do
      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_blob, %{title: "no blob"})
        |> Ash.create!()

      post = Ash.load!(post, :cover_image)
      assert post.cover_image == nil
    end
  end

  describe "AttachBlob change on update" do
    test "attaches blob to existing record" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 100
        )

      AshStorage.Service.Test.upload(blob.key, "direct data", AshStorage.Service.Context.new([]))

      post =
        post
        |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
        |> Ash.update!()

      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image.blob.filename == "photo.jpg"
    end

    test "replaces existing has_one attachment" do
      post = create_post!()

      # First: attach normally
      {:ok, %{blob: old_blob}} =
        Operations.attach(post, :cover_image, "old data",
          filename: "old.jpg",
          content_type: "image/jpeg"
        )

      # Second: prepare and attach via blob
      {:ok, %{blob: new_blob}} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "new.jpg",
          content_type: "image/jpeg",
          byte_size: 200
        )

      AshStorage.Service.Test.upload(
        new_blob.key,
        "new direct data",
        AshStorage.Service.Context.new([])
      )

      post =
        post
        |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: new_blob.id})
        |> Ash.update!()

      # Old file should be purged
      refute AshStorage.Service.Test.exists?(old_blob.key)

      # New attachment in place
      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image.blob.filename == "new.jpg"
    end

    test "re-attaching the already attached has_one blob is a no-op" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "cover data",
          filename: "cover.jpg",
          content_type: "image/jpeg"
        )

      post =
        post
        |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
        |> Ash.update!()

      assert AshStorage.Service.Test.exists?(blob.key)
      assert {:ok, _} = Ash.get(AshStorage.Test.Blob, blob.id)

      post = Ash.load!(post, documents: :blob, cover_image: :blob)
      assert post.cover_image.blob.id == blob.id

      assert [_] =
               AshStorage.Test.Attachment
               |> Ash.Query.filter(post_id == ^post.id and name == "cover_image")
               |> Ash.read!()
    end

    test "re-attaching an already attached has_many blob is a no-op" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :documents,
          filename: "doc.pdf",
          byte_size: 100
        )

      AshStorage.Service.Test.upload(blob.key, "pdf", AshStorage.Service.Context.new([]))

      for _ <- 1..2 do
        post
        |> Ash.Changeset.for_update(:attach_document_blob, %{document_blob_id: blob.id})
        |> Ash.update!()
      end

      post = Ash.load!(post, documents: :blob)
      assert [%{blob: %{id: blob_id}}] = post.documents
      assert blob_id == blob.id
    end

    test "appends to has_many" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :documents,
          filename: "doc1.pdf",
          byte_size: 100
        )

      {:ok, %{blob: blob2}} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :documents,
          filename: "doc2.pdf",
          byte_size: 200
        )

      ctx = AshStorage.Service.Context.new([])
      AshStorage.Service.Test.upload(blob1.key, "pdf1", ctx)
      AshStorage.Service.Test.upload(blob2.key, "pdf2", ctx)

      post =
        post
        |> Ash.Changeset.for_update(:attach_document_blob, %{document_blob_id: blob1.id})
        |> Ash.update!()

      post =
        post
        |> Ash.Changeset.for_update(:attach_document_blob, %{document_blob_id: blob2.id})
        |> Ash.update!()

      post = Ash.load!(post, documents: :blob)
      filenames = Enum.map(post.documents, & &1.blob.filename) |> Enum.sort()
      assert filenames == ["doc1.pdf", "doc2.pdf"]
    end

    test "returns error for nonexistent blob" do
      post = create_post!()

      assert_raise Ash.Error.Unknown, fn ->
        post
        |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: Ash.UUID.generate()})
        |> Ash.update!()
      end
    end
  end
end
