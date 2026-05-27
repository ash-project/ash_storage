defmodule AshStorage.VariantTest do
  use ExUnit.Case, async: false

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post_with_document(content \\ "hello world") do
    post =
      AshStorage.Test.VariantPost
      |> Ash.Changeset.for_create(:create, %{title: "test"})
      |> Ash.create!()

    {:ok, %{record: post}} =
      AshStorage.Operations.attach(post, :document, content,
        filename: "test.txt",
        content_type: "text/plain"
      )

    Ash.load!(post, document: [blob: :variants])
  end

  describe "eager variant generation" do
    test "generates eager variants during attach" do
      post = create_post_with_document()
      blob = post.document.blob
      variants = blob.variants

      # eager_uppercase and custom should be generated, uppercase is on_demand
      assert length(variants) == 2

      eager = Enum.find(variants, &(&1.variant_name == "eager_uppercase"))
      assert eager != nil
      assert eager.variant_of_blob_id == blob.id
      assert eager.content_type == "text/plain"

      {:ok, data} = AshStorage.Service.Test.download(eager.key, [])
      assert data == "HELLO WORLD"
    end

    test "passes opts to transform" do
      post = create_post_with_document()
      blob = post.document.blob

      custom = Enum.find(blob.variants, &(&1.variant_name == "custom"))
      assert custom != nil

      {:ok, data} = AshStorage.Service.Test.download(custom.key, [])
      assert data == "HELLO WORLD!!!"
    end

    test "skips variants that don't accept the content type" do
      post =
        AshStorage.Test.VariantPost
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      {:ok, %{record: post}} =
        AshStorage.Operations.attach(post, :image, "image data",
          filename: "test.png",
          content_type: "image/png"
        )

      post = Ash.load!(post, image: [blob: :variants])
      # RejectAllVariant rejects everything
      assert post.image.blob.variants == []
    end

    test "stores variant metadata on blob" do
      post = create_post_with_document()
      blob = post.document.blob

      eager = Enum.find(blob.variants, &(&1.variant_name == "eager_uppercase"))
      assert eager.variant_digest != nil
      assert is_binary(eager.variant_digest)
      assert String.length(eager.variant_digest) == 16
    end

    test "threads variant content_type to the service on upload" do
      post = create_post_with_document()
      blob = post.document.blob

      assert AshStorage.Service.Test.get_content_type(blob.key) == "text/plain"

      eager = Enum.find(blob.variants, &(&1.variant_name == "eager_uppercase"))
      assert AshStorage.Service.Test.get_content_type(eager.key) == "text/plain"
    end
  end

  describe "on-demand variant generation" do
    test "generates variant via URL calculation on first load" do
      post = create_post_with_document()

      # The :uppercase variant is on_demand, so no variant blob yet
      blob = post.document.blob
      on_demand = Enum.find(blob.variants, &(&1.variant_name == "uppercase"))
      assert on_demand == nil

      # Loading the URL calculation triggers generation
      post = Ash.load!(post, :document_uppercase_url)
      assert post.document_uppercase_url =~ "http://test.local/storage/"

      # Now the variant blob should exist
      post = Ash.load!(post, document: [blob: :variants])
      on_demand = Enum.find(post.document.blob.variants, &(&1.variant_name == "uppercase"))
      assert on_demand != nil

      {:ok, data} = AshStorage.Service.Test.download(on_demand.key, [])
      assert data == "HELLO WORLD"
    end

    test "returns nil when attachment is nil" do
      post =
        AshStorage.Test.VariantPost
        |> Ash.Changeset.for_create(:create, %{title: "no doc"})
        |> Ash.create!()

      post = Ash.load!(post, :document_uppercase_url)
      assert post.document_uppercase_url == nil
    end

    test "reuses existing variant blob on subsequent loads" do
      post = create_post_with_document()

      # First load generates
      post = Ash.load!(post, :document_uppercase_url)
      url1 = post.document_uppercase_url

      # Second load should reuse (same URL)
      post = Ash.load!(post, :document_uppercase_url)
      assert post.document_uppercase_url == url1
    end
  end

  describe "failing variants" do
    test "failing transform does not create a variant blob" do
      post =
        AshStorage.Test.VariantPost
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      {:ok, %{record: post}} =
        AshStorage.Operations.attach(post, :document, "hello",
          filename: "test.txt",
          content_type: "text/plain"
        )

      post = Ash.load!(post, document: [blob: :variants])
      blob = post.document.blob

      # FailingVariant always returns {:error, :transform_failed}
      # Try generating manually
      variant_def = %AshStorage.VariantDefinition{
        name: :fail,
        module: AshStorage.Test.FailingVariant,
        generate: :on_demand
      }

      {:ok, attachment_def} =
        AshStorage.Info.attachment(AshStorage.Test.VariantPost, :document)

      assert {:error, :transform_failed} =
               AshStorage.VariantGenerator.generate(
                 blob,
                 variant_def,
                 AshStorage.Test.VariantPost,
                 attachment_def
               )
    end
  end

  describe "variant digest" do
    test "different opts produce different digests" do
      d1 =
        AshStorage.VariantDefinition.digest(%AshStorage.VariantDefinition{
          name: :test,
          module: {AshStorage.Test.UppercaseVariant, width: 100}
        })

      d2 =
        AshStorage.VariantDefinition.digest(%AshStorage.VariantDefinition{
          name: :test,
          module: {AshStorage.Test.UppercaseVariant, width: 200}
        })

      assert d1 != d2
    end

    test "same opts produce same digests" do
      d1 =
        AshStorage.VariantDefinition.digest(%AshStorage.VariantDefinition{
          name: :test,
          module: AshStorage.Test.UppercaseVariant
        })

      d2 =
        AshStorage.VariantDefinition.digest(%AshStorage.VariantDefinition{
          name: :test,
          module: AshStorage.Test.UppercaseVariant
        })

      assert d1 == d2
    end
  end
end
