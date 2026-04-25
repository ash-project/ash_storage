defmodule AshStorage.SortTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations

  defmodule SortDomain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshStorage.SortTest.SortBlob
      resource AshStorage.SortTest.SortAttachment
      resource AshStorage.SortTest.SortedPost
      resource AshStorage.SortTest.DoBlockSortedPost
      resource AshStorage.SortTest.UnsortedPost
    end
  end

  defmodule SortBlob do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.SortTest.SortDomain,
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

  defmodule SortAttachment do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.SortTest.SortDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage.AttachmentResource]

    ets do
      private? true
    end

    attachment do
      blob_resource(AshStorage.SortTest.SortBlob)
      belongs_to_resource(:sorted_post, AshStorage.SortTest.SortedPost)
      belongs_to_resource(:do_block_sorted_post, AshStorage.SortTest.DoBlockSortedPost)
      belongs_to_resource(:unsorted_post, AshStorage.SortTest.UnsortedPost)
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule SortedPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.SortTest.SortDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.SortTest.SortBlob)
      attachment_resource(AshStorage.SortTest.SortAttachment)

      has_many_attached :documents, sort: [{:blob_id, :asc}]
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, allow_nil?: false
    end

    actions do
      defaults [:read, :destroy, create: [:title], update: [:title]]
    end
  end

  defmodule DoBlockSortedPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.SortTest.SortDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.SortTest.SortBlob)
      attachment_resource(AshStorage.SortTest.SortAttachment)

      has_many_attached :documents do
        sort blob_id: :desc
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

  defmodule UnsortedPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.SortTest.SortDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.SortTest.SortBlob)
      attachment_resource(AshStorage.SortTest.SortAttachment)

      has_many_attached :documents
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

  describe "sort option on has_many_attached" do
    test "relationship has sort when sort option is provided" do
      rel = Ash.Resource.Info.relationship(SortedPost, :documents)
      assert rel.sort == [{:blob_id, :asc}]
    end

    test "relationship has sort when sort is set in do block" do
      rel = Ash.Resource.Info.relationship(DoBlockSortedPost, :documents)
      assert rel.sort == [{:blob_id, :desc}]
    end

    test "relationship has no sort when sort option is omitted" do
      rel = Ash.Resource.Info.relationship(UnsortedPost, :documents)
      assert rel.sort == nil
    end

    test "loading returns attachments in sorted order" do
      post =
        SortedPost
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      {:ok, _} = Operations.attach(post, :documents, "aaa", filename: "a.txt")
      {:ok, _} = Operations.attach(post, :documents, "bbb", filename: "b.txt")
      {:ok, _} = Operations.attach(post, :documents, "ccc", filename: "c.txt")

      post = Ash.load!(post, :documents)
      blob_ids = Enum.map(post.documents, & &1.blob_id)
      assert blob_ids == Enum.sort(blob_ids)
    end

    test "sort can be overridden when loading" do
      post =
        SortedPost
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      {:ok, _} = Operations.attach(post, :documents, "aaa", filename: "a.txt")
      {:ok, _} = Operations.attach(post, :documents, "bbb", filename: "b.txt")
      {:ok, _} = Operations.attach(post, :documents, "ccc", filename: "c.txt")

      query = Ash.Query.sort(SortAttachment, blob_id: :desc)
      post = Ash.load!(post, documents: query)
      blob_ids = Enum.map(post.documents, & &1.blob_id)
      assert blob_ids == Enum.sort(blob_ids, :desc)
    end
  end
end
