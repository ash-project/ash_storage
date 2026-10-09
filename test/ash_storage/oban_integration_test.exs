defmodule AshStorage.ObanIntegrationTest do
  use AshStorage.RepoCase, async: false
  use Oban.Testing, repo: AshStorage.TestRepo

  require Ash.Query

  @moduletag :oban

  alias AshStorage.Test.{PgBlob, PgPost}

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test post") do
    PgPost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  describe "service_opts persistence" do
    test "attach persists service_opts on the blob" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      # Test service has no service_opts_fields, so should be empty
      assert blob.service_opts == %{}
    end
  end

  describe "parsed_service_opts calculation" do
    test "reconstitutes service opts from stored map" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      blob = Ash.load!(blob, :parsed_service_opts)
      # Test service doesn't define service_opts_fields, returns []
      assert blob.parsed_service_opts == []
    end
  end

  describe "mark_for_purge" do
    test "marks blob as pending_purge without deleting file" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      assert AshStorage.Service.Test.exists?(blob.key)
      refute blob.pending_purge

      {:ok, [marked_blob]} =
        AshStorage.Operations.mark_attachments_for_purge(post, :cover_image)

      assert marked_blob.pending_purge
      # File still exists - not deleted yet
      assert AshStorage.Service.Test.exists?(blob.key)
    end
  end

  describe "purge_blob action" do
    test "deletes file from storage and destroys blob record" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      assert AshStorage.Service.Test.exists?(blob.key)

      # Detach the attachment first (as mark_attachments_for_purge would)
      AshStorage.Operations.detach(post, :cover_image)

      # Run the purge_blob action directly
      Ash.destroy!(blob, action: :purge_blob)

      refute AshStorage.Service.Test.exists?(blob.key)
      assert {:error, _} = Ash.get(PgBlob, blob.id)
    end

    test "a bulk purge deletes each file from storage" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      AshStorage.Operations.detach(post, :cover_image)

      assert %Ash.BulkResult{status: :success} =
               PgBlob
               |> Ash.Query.filter(id == ^blob.id)
               |> Ash.bulk_destroy!(:purge_blob, %{}, strategy: [:atomic, :stream])

      refute AshStorage.Service.Test.exists?(blob.key)
      assert {:error, _} = Ash.get(PgBlob, blob.id)
    end
  end

  describe "async dependent purge" do
    test "destroying record marks blobs for purge instead of deleting files" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      assert AshStorage.Service.Test.exists?(blob.key)

      # PgBlob has AshOban, so destroy should use async path
      Ash.destroy!(post)

      # File should still exist (marked for async purge, not deleted yet)
      assert AshStorage.Service.Test.exists?(blob.key)

      # Blob should still exist but be marked pending_purge
      marked_blob = Ash.get!(PgBlob, blob.id)
      assert marked_blob.pending_purge
    end

    test "executing the purge_blob trigger cleans up marked blobs" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :cover_image, "image data", filename: "photo.jpg")

      Ash.destroy!(post)

      # Blob is marked for purge
      marked_blob = Ash.get!(PgBlob, blob.id)
      assert marked_blob.pending_purge

      # Simulate what the AshOban trigger would do
      Ash.destroy!(marked_blob, action: :purge_blob)

      # Now the file and blob should be gone
      refute AshStorage.Service.Test.exists?(blob.key)
      assert {:error, _} = Ash.get(PgBlob, blob.id)
    end

    test "detach-dependent attachments still work (documents)" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :documents, "doc data", filename: "doc.txt")

      Ash.destroy!(post)

      # File still exists (detach, not purge)
      assert AshStorage.Service.Test.exists?(blob.key)
      # Blob still exists and is NOT marked for purge
      existing_blob = Ash.get!(PgBlob, blob.id)
      refute existing_blob.pending_purge
    end
  end
end
