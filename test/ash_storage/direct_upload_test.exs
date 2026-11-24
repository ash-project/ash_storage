defmodule AshStorage.DirectUploadTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshStorage.Operations

  defmodule CountingService do
    @moduledoc false
    # The Test service, telling the test process about every read
    @behaviour AshStorage.Service

    alias AshStorage.Service.Test

    @impl true
    def upload(key, data, ctx), do: Test.upload(key, data, ctx)

    @impl true
    def download(key, ctx) do
      send(self(), {:download, key})
      Test.download(key, ctx)
    end

    @impl true
    def head(key, ctx) do
      send(self(), {:head, key})
      Test.head(key, ctx)
    end

    @impl true
    def delete(key, ctx), do: Test.delete(key, ctx)

    @impl true
    def exists?(key, ctx), do: Test.exists?(key, ctx)

    @impl true
    def url(key, ctx), do: Test.url(key, ctx)

    @impl true
    def direct_upload(key, ctx), do: Test.direct_upload(key, ctx)
  end

  defmodule CountingDomain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshStorage.DirectUploadTest.CountingPost
    end
  end

  defmodule CountingPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.DirectUploadTest.CountingDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.DirectUploadTest.CountingService, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)

      has_one_attached(:plain)

      has_one_attached :images_only do
        analyzer(AshStorage.Test.ImageAnalyzer)
      end

      has_one_attached :analyzed do
        analyzer(AshStorage.Test.TestAnalyzer)
      end
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: []]

      for name <- [:plain, :images_only, :analyzed] do
        update :"attach_#{name}_blob" do
          require_atomic? false
          argument :blob_id, :uuid, allow_nil?: true

          change {AshStorage.Changes.AttachBlob, argument: :blob_id, attachment: name}
        end
      end
    end
  end

  defp uploaded!(resource, name, content, content_type \\ "text/plain") do
    {:ok, %{blob: blob}} =
      Operations.prepare_direct_upload(resource, name,
        filename: "f.txt",
        content_type: content_type,
        byte_size: byte_size(content)
      )

    :ok = AshStorage.Service.Test.upload(blob.key, content, AshStorage.Service.Context.new([]))
    blob
  end

  defp attach_counting(post, name, blob) do
    post
    |> Ash.Changeset.for_update(:"attach_#{name}_blob", %{blob_id: blob.id})
    |> Ash.update()
  end

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

  describe "AttachBlob reads the object only when it has to" do
    test "no download without an analyzer or an eager variant" do
      post = Ash.create!(CountingPost, %{})
      blob = uploaded!(CountingPost, :plain, "hello")

      assert {:ok, _} = attach_counting(post, :plain, blob)
      refute_received {:download, _}
    end

    test "no download when no analyzer accepts the content type" do
      post = Ash.create!(CountingPost, %{})
      blob = uploaded!(CountingPost, :images_only, "hello")

      assert {:ok, _} = attach_counting(post, :images_only, blob)
      refute_received {:download, _}
    end

    test "one download for an eager analyzer that accepts the content type" do
      post = Ash.create!(CountingPost, %{})
      blob = uploaded!(CountingPost, :analyzed, "one\ntwo")

      assert {:ok, post} = attach_counting(post, :analyzed, blob)
      key = blob.key
      assert_received {:download, ^key}
      refute_received {:download, _}
      assert post.__metadata__[:analyzed_blob].metadata["line_count"] == 2
    end

    test "the blob already attached, sent again, asks the service nothing" do
      post = Ash.create!(CountingPost, %{})
      blob = uploaded!(CountingPost, :analyzed, "one\ntwo")
      {:ok, post} = attach_counting(post, :analyzed, blob)
      analyzers = post.__metadata__[:analyzed_blob].analyzers
      flush_reads()

      assert {:ok, post} = attach_counting(post, :analyzed, blob)
      refute_received {:head, _}
      refute_received {:download, _}
      assert Ash.get!(AshStorage.Test.Blob, blob.id).analyzers == analyzers
      assert post.__metadata__[:analyzed_attachment].blob_id == blob.id
    end
  end

  describe "AttachBlob on an upsert" do
    test "re-sending the blob the record already has does not derive it again" do
      blob = uploaded!(AshStorage.Test.MatrixPost, :doc, "shout")

      for _ <- 1..2 do
        Ash.create!(AshStorage.Test.MatrixPost, %{slug: "resent", doc_blob_id: blob.id},
          action: :upsert_with_doc_blob
        )
      end

      assert [%{variant_name: "upper"}] = Ash.load!(blob, :variants).variants
    end
  end

  describe "AttachBlob refuses blobs that cannot be attached" do
    test "a variant blob" do
      post = create_post!()

      {:ok, %{blob: source}} =
        AshStorage.Operations.attach(
          Ash.create!(AshStorage.Test.VariantPost, %{title: "v"}),
          :document,
          "hello",
          filename: "a.txt",
          content_type: "text/plain"
        )

      [variant | _] = Ash.load!(source, :variants).variants

      assert {:error, error} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: variant.id})
               |> Ash.update()

      assert Exception.message(error) =~ "blob_not_found"
      assert Ash.load!(post, :cover_image).cover_image == nil
    end

    test "a blob marked for purge" do
      post = create_post!()
      blob = uploaded!(AshStorage.Test.Post, :cover_image, "marked")
      Ash.Seed.update!(blob, %{pending_purge: true})

      assert {:error, error} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
               |> Ash.update()

      assert Exception.message(error) =~ "blob_not_found"
      assert Ash.load!(post, :cover_image).cover_image == nil
    end

    test "an unknown blob id fails a create before the record is written" do
      assert {:error, _} =
               AshStorage.Test.Post
               |> Ash.Changeset.for_create(:create_with_blob, %{
                 title: "never written",
                 cover_image_blob_id: Ash.UUID.generate()
               })
               |> Ash.create()

      assert [] =
               AshStorage.Test.Post
               |> Ash.Query.filter(title == "never written")
               |> Ash.read!()
    end
  end

  defp flush_reads do
    receive do
      {kind, _} when kind in [:head, :download] -> flush_reads()
    after
      0 -> :ok
    end
  end
end
