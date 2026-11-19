defmodule AshStorage.UrlTest do
  use ExUnit.Case, async: false

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test post") do
    AshStorage.Test.Post
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  describe "has_one URL calculation" do
    test "returns nil when no attachment" do
      post = create_post!() |> Ash.load!(:cover_image_url)
      assert post.cover_image_url == nil
    end

    test "returns URL when attachment exists" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "data",
          filename: "photo.jpg",
          content_type: "image/jpeg"
        )

      post = Ash.load!(post, :cover_image_url)
      assert post.cover_image_url == "http://test.local/storage/#{blob.key}"
    end
  end

  describe "has_many URL calculation" do
    test "returns empty list when no attachments" do
      post = create_post!() |> Ash.load!(:documents_urls)
      assert post.documents_urls == []
    end

    test "returns list of URLs when attachments exist" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        AshStorage.Operations.attach(post, :documents, "doc1",
          filename: "a.txt",
          content_type: "text/plain"
        )

      {:ok, %{blob: blob2}} =
        AshStorage.Operations.attach(post, :documents, "doc2",
          filename: "b.txt",
          content_type: "text/plain"
        )

      post = Ash.load!(post, :documents_urls)

      expected =
        [blob1.key, blob2.key]
        |> Enum.map(&"http://test.local/storage/#{&1}")
        |> Enum.sort()

      assert Enum.sort(post.documents_urls) == expected
    end
  end

  describe "attachment URL calculation" do
    test "returns URL for has_one attachment" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "data",
          filename: "photo.jpg",
          content_type: "image/jpeg"
        )

      post = Ash.load!(post, cover_image: [:url])
      assert post.cover_image.url == "http://test.local/storage/#{blob.key}"
    end

    test "returns URLs for has_many attachments" do
      post = create_post!()

      {:ok, %{blob: blob1}} =
        AshStorage.Operations.attach(post, :documents, "doc1",
          filename: "a.txt",
          content_type: "text/plain"
        )

      {:ok, %{blob: blob2}} =
        AshStorage.Operations.attach(post, :documents, "doc2",
          filename: "b.txt",
          content_type: "text/plain"
        )

      post = Ash.load!(post, documents: [:url])

      urls =
        post.documents
        |> Enum.map(& &1.url)
        |> Enum.sort()

      expected =
        [blob1.key, blob2.key]
        |> Enum.map(&"http://test.local/storage/#{&1}")
        |> Enum.sort()

      assert urls == expected
    end
  end

  describe "attachment URL calculation with variants" do
    defp create_variant_post! do
      AshStorage.Test.VariantPost
      |> Ash.Changeset.for_create(:create, %{title: "test"})
      |> Ash.create!()
    end

    test "returns source blob URL when variants exist" do
      post = create_variant_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :document, "hello",
          filename: "test.txt",
          content_type: "text/plain"
        )

      post = Ash.load!(post, document: [:url])
      assert post.document.url == "http://test.local/storage/#{blob.key}"
    end

    test "source blob URL is distinct from variant URLs" do
      post = create_variant_post!()

      {:ok, _} =
        AshStorage.Operations.attach(post, :document, "hello",
          filename: "test.txt",
          content_type: "text/plain"
        )

      post = Ash.load!(post, [:document_eager_uppercase_url, document: [:url]])

      # Attachment url is the source blob URL
      # Variant url is a different blob's URL
      assert post.document.url != post.document_eager_uppercase_url
    end
  end

  describe "Disk signed URLs" do
    test "generates plain URL without secret" do
      ctx =
        AshStorage.Service.Context.new(
          root: "/tmp/storage",
          base_url: "/files"
        )

      url = AshStorage.Service.Disk.url("abc/123", ctx)
      assert url == "/files/abc/123"
    end

    test "generates signed URL with secret" do
      ctx =
        AshStorage.Service.Context.new(
          root: "/tmp/storage",
          base_url: "/files",
          secret: "my-secret-key"
        )

      url = AshStorage.Service.Disk.url("abc/123", ctx)
      assert url =~ "/files/abc/123?"
      assert url =~ "token="
      assert url =~ "expires="
    end

    test "includes disposition in signed URL" do
      ctx =
        AshStorage.Service.Context.new(
          root: "/tmp/storage",
          base_url: "/files",
          secret: "my-secret-key",
          disposition: "attachment",
          filename: "download.txt"
        )

      url = AshStorage.Service.Disk.url("abc/123", ctx)
      assert url =~ "disposition=attachment"
      assert url =~ "filename=download.txt"
    end
  end

  describe "blob metadata on the url/2 context" do
    @describetag :tmp_dir

    defp use_service(service) do
      Application.put_env(:ash_storage, AshStorage.Test.VariantPost, storage: [service: service])
      on_exit(fn -> Application.delete_env(:ash_storage, AshStorage.Test.VariantPost) end)
    end

    defp variant_post_with_document! do
      post =
        AshStorage.Test.VariantPost
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :document, "hello",
          filename: "notes.txt",
          content_type: "text/plain"
        )

      post =
        Ash.load!(post, [:document_eager_uppercase_url, document: [:url, blob: :variants]])

      variant = Enum.find(post.document.blob.variants, &(&1.variant_name == "eager_uppercase"))
      {post, blob, variant}
    end

    # Two notes, each with its eager variant; returns the variant blobs.
    defp variant_post_with_notes! do
      post =
        AshStorage.Test.VariantPost
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      for filename <- ["a.txt", "b.txt"] do
        {:ok, _} =
          AshStorage.Operations.attach(post, :notes, filename,
            filename: filename,
            content_type: "text/plain"
          )
      end

      post = Ash.load!(post, [:notes_eager_uppercase_urls, notes: [blob: :variants]])
      variants = Enum.flat_map(post.notes, & &1.blob.variants)
      assert length(variants) == 2
      {post, variants}
    end

    test "a Disk attachment URL carries the blob's filename", %{tmp_dir: tmp_dir} do
      use_service({AshStorage.Service.Disk, root: tmp_dir, base_url: "/files"})

      {post, blob, _variant} = variant_post_with_document!()

      assert post.document.url == "/files/#{blob.key}?filename=notes.txt"
    end

    test "a Disk variant URL carries the variant blob's filename", %{tmp_dir: tmp_dir} do
      use_service({AshStorage.Service.Disk, root: tmp_dir, base_url: "/files"})

      {post, _blob, variant} = variant_post_with_document!()

      assert post.document_eager_uppercase_url ==
               "/files/#{variant.key}?filename=eager_uppercase_notes.txt"
    end

    test "Disk variant URLs of a has_many attachment carry each variant blob's filename", %{
      tmp_dir: tmp_dir
    } do
      use_service({AshStorage.Service.Disk, root: tmp_dir, base_url: "/files"})

      {post, variants} = variant_post_with_notes!()

      expected = Enum.map(variants, &"/files/#{&1.key}?filename=#{&1.filename}")
      assert Enum.sort(post.notes_eager_uppercase_urls) == Enum.sort(expected)
    end

    test "Disk URLs of a has_many attachment carry each blob's filename", %{tmp_dir: tmp_dir} do
      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          has_many_attached: [
            mirrored_documents: [
              service: {AshStorage.Service.Disk, root: tmp_dir, base_url: "/files"}
            ]
          ]
        ]
      )

      on_exit(fn -> Application.delete_env(:ash_storage, AshStorage.Test.ConfigurablePost) end)

      post =
        AshStorage.Test.ConfigurablePost
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      blobs =
        for filename <- ["a.txt", "b.txt"] do
          {:ok, %{blob: blob}} =
            AshStorage.Operations.attach(post, :mirrored_documents, filename,
              filename: filename,
              content_type: "text/plain"
            )

          blob
        end

      post = Ash.load!(post, :mirrored_documents_urls)

      expected = Enum.map(blobs, &"/files/#{&1.key}?filename=#{&1.filename}")
      assert Enum.sort(post.mirrored_documents_urls) == Enum.sort(expected)
    end

    test "the service sees the blob's content type and filename" do
      use_service({AshStorage.Test.ContextCapturingService, []})

      {_post, blob, variant} = variant_post_with_document!()

      for {key, filename} <- [{blob.key, "notes.txt"}, {variant.key, "eager_uppercase_notes.txt"}] do
        ctx = AshStorage.Test.ContextCapturingService.captured_url_context(key)

        assert ctx.content_type == "text/plain"
        assert ctx.filename == filename
        refute Keyword.has_key?(ctx.service_opts, :original_filename)
      end
    end
  end
end
