defmodule AshStorage.DependentPgTest do
  # The synchronous `dependent: :purge` destroy on Postgres: a blob resource
  # without AshOban, over the same tables as the Pg* test resources.
  use AshStorage.RepoCase, async: false

  alias AshStorage.Operations

  @moduletag :oban

  defmodule Domain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshStorage.DependentPgTest.SyncBlob
      resource AshStorage.DependentPgTest.SyncAttachment
      resource AshStorage.DependentPgTest.SyncPost
    end
  end

  defmodule SyncBlob do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.DependentPgTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStorage.BlobResource]

    postgres do
      table "storage_blobs"
      repo(AshStorage.TestRepo)
    end

    blob do
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule SyncAttachment do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.DependentPgTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStorage.AttachmentResource]

    postgres do
      table "storage_attachments"
      repo(AshStorage.TestRepo)
    end

    attachment do
      blob_resource(AshStorage.DependentPgTest.SyncBlob)
      belongs_to_resource(:post, AshStorage.DependentPgTest.SyncPost)
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule SyncPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.DependentPgTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshStorage]

    postgres do
      table "posts"
      repo(AshStorage.TestRepo)
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.DependentPgTest.SyncBlob)
      attachment_resource(AshStorage.DependentPgTest.SyncAttachment)

      has_one_attached(:cover_image)
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy, create: [:title]]
    end
  end

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  test "a destroy in the caller's transaction that fails later keeps the rows and the file" do
    post = Ash.create!(SyncPost, %{title: "kept"})
    {:ok, %{blob: blob}} = Operations.attach(post, :cover_image, "kept", filename: "kept.bin")

    TestRepo.transaction(fn ->
      post
      |> Ash.Changeset.for_destroy(:destroy)
      |> Ash.Changeset.after_action(fn _, _ -> {:error, "a later hook failed"} end)
      |> Ash.destroy()
    end)

    assert {:ok, _} = Ash.get(SyncPost, post.id)
    assert Ash.load!(post, :cover_image).cover_image.blob_id == blob.id
    assert {:ok, _} = Ash.get(SyncBlob, blob.id)
    assert AshStorage.Service.Test.exists?(blob.key)
  end

  test "the destroyed record carries no private metadata" do
    post = Ash.create!(SyncPost, %{title: "meta"})
    {:ok, _} = Operations.attach(post, :cover_image, "gone", filename: "gone.bin")

    assert {:ok, destroyed} = Ash.destroy(post, return_destroyed?: true)
    refute Map.has_key?(destroyed.__metadata__, :__ash_storage_deletions__)
  end
end
