defmodule AshStorage.ChecksumVerificationTest do
  use ExUnit.Case, async: false

  alias AshStorage.Service.Context
  alias AshStorage.Test.ChecksumVerifyingPost
  alias AshStorage.Test.ChecksumVerifyingService

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test post") do
    ChecksumVerifyingPost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  describe "ChecksumVerifyingService.upload/3" do
    test "stores when expected_md5 matches the body" do
      ctx = Context.put_expected_md5(Context.new([]), encoded_md5("hello"))
      assert :ok = ChecksumVerifyingService.upload("k", "hello", ctx)
      assert {:ok, "hello"} = AshStorage.Service.Test.download("k", [])
    end

    test "rejects when expected_md5 doesn't match the body" do
      ctx = Context.put_expected_md5(Context.new([]), encoded_md5("other"))
      assert {:error, :checksum_mismatch} = ChecksumVerifyingService.upload("k", "hello", ctx)
      refute AshStorage.Service.Test.exists?("k")
    end

    test "rejects when expected_md5 is missing" do
      assert {:error, :missing_expected_md5} =
               ChecksumVerifyingService.upload("k", "hello", Context.new([]))
    end
  end

  describe "Operations.attach threads expected_md5 to the service" do
    test "attach succeeds with a verifying service" do
      post = create_post!()

      assert {:ok, %{blob: blob}} =
               AshStorage.Operations.attach(post, :cover_image, "hello world",
                 filename: "hello.txt",
                 content_type: "text/plain"
               )

      assert blob.checksum == encoded_md5("hello world")
      assert {:ok, "hello world"} = AshStorage.Service.Test.download(blob.key, [])
    end
  end

  describe "AttachFile threads expected_md5 to the service" do
    test "create_with_image succeeds against a verifying service" do
      path = Path.join(System.tmp_dir!(), "checksum_attach_file.txt")
      File.write!(path, "from disk")

      post =
        ChecksumVerifyingPost
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "with image",
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)
      blob = post.cover_image.blob

      assert blob.checksum == encoded_md5("from disk")
      assert {:ok, "from disk"} = AshStorage.Service.Test.download(blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "checksum_attach_file.txt"))
    end
  end

  describe "AttachBlob auto-confirm (Test service: returns content_md5)" do
    setup do
      AshStorage.Service.Test.reset!()
      :ok
    end

    test "attaches when blob.checksum matches storage" do
      data = "direct upload payload"

      {:ok, %{blob: blob}} =
        AshStorage.Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "f.txt",
          checksum: encoded_md5(data)
        )

      :ok = AshStorage.Service.Test.upload(blob.key, data, AshStorage.Service.Context.new([]))

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create, %{title: "p"})
        |> Ash.create!()

      assert {:ok, _post} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
               |> Ash.update()
    end

    test "fails with checksum_mismatch when blob.checksum disagrees with storage" do
      {:ok, %{blob: blob}} =
        AshStorage.Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "f.txt",
          checksum: encoded_md5("expected")
        )

      :ok =
        AshStorage.Service.Test.upload(blob.key, "actual", AshStorage.Service.Context.new([]))

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create, %{title: "p"})
        |> Ash.create!()

      assert {:error, error} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
               |> Ash.update()

      assert Exception.message(error) =~ "checksum_mismatch"
    end

    test "populates blob.checksum from storage when empty at prepare time" do
      data = "no expected md5"

      {:ok, %{blob: blob}} =
        AshStorage.Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "f.txt"
        )

      assert blob.checksum in [nil, ""]

      :ok = AshStorage.Service.Test.upload(blob.key, data, AshStorage.Service.Context.new([]))

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create, %{title: "p"})
        |> Ash.create!()

      assert {:ok, _post} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
               |> Ash.update()

      reloaded = Ash.get!(AshStorage.Test.Blob, blob.id)
      assert reloaded.checksum == encoded_md5(data)
    end
  end

  describe "AttachBlob auto-confirm fallbacks" do
    setup do
      AshStorage.Service.Test.reset!()
      :ok
    end

    test "links without verification when service does not implement head/2" do
      {:ok, %{blob: blob}} =
        AshStorage.Operations.prepare_direct_upload(AshStorage.Test.NoHeadPost, :cover_image,
          filename: "f.txt"
        )

      :ok =
        AshStorage.Service.Test.upload(blob.key, "anything", AshStorage.Service.Context.new([]))

      post =
        AshStorage.Test.NoHeadPost
        |> Ash.Changeset.for_create(:create, %{title: "p"})
        |> Ash.create!()

      assert {:ok, _post} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
               |> Ash.update()
    end

    test "links silently when service returns multipart-style ETag and blob.checksum empty" do
      {:ok, %{blob: blob}} =
        AshStorage.Operations.prepare_direct_upload(
          AshStorage.Test.MultipartEtagPost,
          :cover_image,
          filename: "f.txt"
        )

      post =
        AshStorage.Test.MultipartEtagPost
        |> Ash.Changeset.for_create(:create, %{title: "p"})
        |> Ash.create!()

      assert {:ok, _post} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
               |> Ash.update()
    end

    test "fails with :checksum_unverifiable when service can't report and blob.checksum is set" do
      {:ok, %{blob: blob}} =
        AshStorage.Operations.prepare_direct_upload(
          AshStorage.Test.MultipartEtagPost,
          :cover_image,
          filename: "f.txt",
          checksum: encoded_md5("some bytes")
        )

      post =
        AshStorage.Test.MultipartEtagPost
        |> Ash.Changeset.for_create(:create, %{title: "p"})
        |> Ash.create!()

      assert {:error, error} =
               post
               |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
               |> Ash.update()

      assert Exception.message(error) =~ "checksum_unverifiable"
      refute Exception.message(error) =~ "checksum_mismatch"
    end
  end

  describe "VariantGenerator threads expected_md5 to the service" do
    test "eager variant uploads through the verifying service" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :document, "hello world",
          filename: "doc.txt",
          content_type: "text/plain"
        )

      blob = Ash.load!(blob, :variants)
      variant = Enum.find(blob.variants, &(&1.variant_name == "eager_uppercase"))

      assert variant
      assert variant.checksum == encoded_md5("HELLO WORLD")
      assert {:ok, "HELLO WORLD"} = AshStorage.Service.Test.download(variant.key, [])
    end
  end

  defp encoded_md5(data), do: data |> :erlang.md5() |> Base.encode64()
end
