defmodule AshStorage.PurgeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store
  alias AshStorage.Test.{Blob, Post, VariantPost}

  setup do
    Store.reset!()
    :ok
  end

  test "purging a blob removes its variants and their files" do
    post = Ash.create!(VariantPost, %{title: "variants"})

    {:ok, %{blob: blob}} =
      Operations.attach(post, :document, "hello", filename: "a.txt", content_type: "text/plain")

    variants = Ash.load!(blob, :variants).variants
    assert length(variants) == 2

    assert {:ok, [_]} = Operations.purge(post, :document)

    assert Store.list_keys() == []
    assert {:error, _} = Ash.get(Blob, blob.id)

    for variant <- variants do
      assert {:error, _} = Ash.get(Blob, variant.id)
    end
  end

  test "a variant that another record has attached is kept" do
    post = Ash.create!(AshStorage.Test.MatrixPost, %{slug: "source"})
    other = Ash.create!(AshStorage.Test.MatrixPost, %{slug: "other"})

    {:ok, %{blob: source}} =
      Operations.attach(post, :doc, "shout", filename: "a.txt", content_type: "text/plain")

    [variant] = Ash.load!(source, :variants).variants

    Ash.create!(AshStorage.Test.PolymorphicAttachment, %{
      name: "plain",
      record_type: AshStorage.Info.record_type(AshStorage.Test.MatrixPost),
      record_id: other.id,
      blob_id: variant.id
    })

    assert {:ok, [_]} = Operations.purge(post, :doc)

    assert {:error, _} = Ash.get(Blob, source.id)
    refute Store.exists?(source.key)
    assert {:ok, _} = Ash.get(Blob, variant.id)
    assert Store.exists?(variant.key)
  end

  test "an attachment row whose blob is gone can still be detached and purged" do
    post = Ash.create!(Post, %{title: "orphans"})
    {:ok, %{blob: one}} = Operations.attach(post, :documents, "1", filename: "1.txt")
    {:ok, %{blob: two}} = Operations.attach(post, :documents, "2", filename: "2.txt")
    Ash.destroy!(one)
    Ash.destroy!(two)

    assert {:ok, [_]} = Operations.detach(post, :documents, blob_id: one.id)
    assert {:ok, [_]} = Operations.purge(post, :documents, blob_id: two.id)
    assert Ash.load!(post, :documents).documents == []
  end

  test "a blob two records share is removed with the last of them" do
    post = Ash.create!(Post, %{title: "one"})
    other = Ash.create!(Post, %{title: "two"})
    {:ok, %{blob: blob}} = Operations.attach(post, :cover_image, "shared", filename: "s.txt")

    other =
      other
      |> Ash.Changeset.for_update(:attach_blob, %{cover_image_blob_id: blob.id})
      |> Ash.update!()

    assert {:ok, [_]} = Operations.purge(post, :cover_image)
    assert {:ok, _} = Ash.get(Blob, blob.id)
    assert Store.exists?(blob.key)
    assert Ash.load!(other, cover_image: :blob).cover_image.blob.id == blob.id

    assert {:ok, [_]} = Operations.purge(other, :cover_image)
    assert {:error, _} = Ash.get(Blob, blob.id)
    refute Store.exists?(blob.key)
  end

  test "a file that cannot be deleted is logged and the purge succeeds" do
    post = Ash.create!(Post, %{title: "stuck"})
    {:ok, %{blob: blob}} = Operations.attach(post, :cover_image, "stuck", filename: "s.txt")
    Ash.Seed.update!(blob, %{service_name: AshStorage.Test.FailingDeleteService})

    log = capture_log(fn -> assert {:ok, [_]} = Operations.purge(post, :cover_image) end)

    assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ blob.key))
    assert line =~ "FailingDeleteService"
    assert {:error, _} = Ash.get(Blob, blob.id)
    assert Ash.load!(post, :cover_image).cover_image == nil
    assert Store.exists?(blob.key)
  end

  test "the returned record carries the purged attachments and nothing private" do
    post = Ash.create!(Post, %{title: "meta"})
    {:ok, %{attachment: attachment}} = Operations.attach(post, :cover_image, "x", filename: "x")

    record =
      post
      |> Ash.Changeset.for_update(:purge_cover_image, %{})
      |> Ash.update!()

    assert [%{id: id}] = record.__metadata__[:purged_attachments]
    assert id == attachment.id
    refute Map.has_key?(record.__metadata__, :__ash_storage_deletions__)
  end
end
