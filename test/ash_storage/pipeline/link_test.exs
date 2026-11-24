defmodule AshStorage.Pipeline.LinkTest do
  use ExUnit.Case, async: false

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Scope, Source}
  alias AshStorage.Test.{Blob, Post}

  setup do
    AshStorage.Service.Test.reset!()
    %{post: Ash.create!(Post, %{title: "link"})}
  end

  defp target!(name) do
    {:ok, target} = Pipeline.resolve(Post, name)
    target
  end

  defp blob!(target, content) do
    {:ok, blob, :stored} = Pipeline.store(Source.new(content), target, %Scope{}, nil)
    blob
  end

  defp rows(post, target) do
    {:ok, rows} = Pipeline.attachments(post, target, %Scope{})
    rows
  end

  describe "has_many" do
    test "linking the same blob twice keeps one row", %{post: post} do
      target = target!(:documents)
      blob = blob!(target, "one")

      assert {:ok, %{attachment: first, deletions: [], kept?: false}} =
               Pipeline.link(post, blob, target, %Scope{})

      assert {:ok, %{attachment: second, deletions: [], kept?: true}} =
               Pipeline.link(post, blob, target, %Scope{})

      assert first.id == second.id
      assert [_] = rows(post, target)
    end

    test "two blobs get two rows", %{post: post} do
      target = target!(:documents)

      {:ok, _} = Pipeline.link(post, blob!(target, "one"), target, %Scope{})
      {:ok, _} = Pipeline.link(post, blob!(target, "two"), target, %Scope{})

      assert [_, _] = rows(post, target)
    end
  end

  describe "has_one" do
    test "linking a second blob removes the first row and blob", %{post: post} do
      target = target!(:cover_image)
      first = blob!(target, "one")
      second = blob!(target, "two")

      {:ok, _} = Pipeline.link(post, first, target, %Scope{})

      assert {:ok, %{attachment: attachment, deletions: [{_service, _ctx, key}]}} =
               Pipeline.link(post, second, target, %Scope{})

      assert key == first.key
      assert [%{id: id, blob_id: blob_id}] = rows(post, target)
      assert {id, blob_id} == {attachment.id, second.id}
      assert {:error, _} = Ash.get(Blob, first.id)
    end

    test "linking the blob that is already linked keeps its row", %{post: post} do
      target = target!(:cover_image)
      blob = blob!(target, "one")

      {:ok, %{attachment: first, kept?: false}} = Pipeline.link(post, blob, target, %Scope{})

      assert {:ok, %{attachment: again, deletions: [], kept?: true}} =
               Pipeline.link(post, blob, target, %Scope{})

      assert again.id == first.id
      assert [_] = rows(post, target)
    end
  end
end
