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
end
