defmodule AshStorage.StorageKeySafetyTest do
  # async: false — exercises the shared AshStorage.Service.Test store.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshStorage.Operations

  defmodule Domain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshStorage.StorageKeySafetyTest.Blob
      resource AshStorage.StorageKeySafetyTest.Attachment
      resource AshStorage.StorageKeySafetyTest.Post
    end
  end

  defmodule Blob do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.StorageKeySafetyTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage.BlobResource]

    ets do
      private? true
    end

    blob do
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule Attachment do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.StorageKeySafetyTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage.AttachmentResource]

    ets do
      private? true
    end

    attachment do
      blob_resource(AshStorage.StorageKeySafetyTest.Blob)
      belongs_to_resource(:post, AshStorage.StorageKeySafetyTest.Post)
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.StorageKeySafetyTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.StorageKeySafetyTest.Blob)
      attachment_resource(AshStorage.StorageKeySafetyTest.Attachment)

      has_one_attached :escape_artist do
        path fn _ctx, _changeset -> "../../etc/#{AshStorage.generate_key()}" end
      end

      has_one_attached :absolutist do
        path fn _ctx, _changeset -> "/etc/passwd" end
      end

      has_one_attached :empty_keyed do
        path fn _ctx, _changeset -> "" end
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, allow_nil?: false
    end

    actions do
      defaults [:read, :destroy, create: [:title], update: [:title]]
    end
  end

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp post! do
    Post
    |> Ash.Changeset.for_create(:create, %{title: "post"})
    |> Ash.create!()
  end

  describe "derived keys are validated before reaching the service" do
    test "a path that escapes its root fails the write" do
      assert {:error, error} = Operations.attach(post!(), :escape_artist, "data", filename: "x")
      assert inspect(error) =~ "unsafe_storage_key"
      assert AshStorage.Service.Test.list_keys() == []
    end

    test "an absolute path fails the write" do
      assert {:error, error} = Operations.attach(post!(), :absolutist, "data", filename: "x")
      assert inspect(error) =~ "unsafe_storage_key"
      assert AshStorage.Service.Test.list_keys() == []
    end

    test "an empty key fails the write" do
      assert {:error, error} = Operations.attach(post!(), :empty_keyed, "data", filename: "x")
      assert inspect(error) =~ "empty_storage_key"
      assert AshStorage.Service.Test.list_keys() == []
    end
  end

  describe "direct uploads with a declared path" do
    test "warn that the path function is ignored" do
      log =
        capture_log(fn ->
          {:ok, _result} =
            Operations.prepare_direct_upload(Post, :escape_artist,
              filename: "photo.jpg",
              content_type: "image/jpeg",
              byte_size: 1
            )
        end)

      assert log =~ "declares a `path` for storage keys"
    end
  end
end
