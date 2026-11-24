defmodule AshStorage.Pipeline.OwnerTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Owner, Scope, Target}
  alias AshStorage.Test.{ConfigurablePost, IntegerAttachment, IntegerPost, Post}

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp target!(resource, name) do
    {:ok, target} = Pipeline.resolve(resource, name)
    target
  end

  describe "keys/2" do
    test "a belongs_to_resource attachment resource uses its foreign key" do
      post = %Post{id: Ash.UUID.generate()}

      assert Owner.keys(target!(Post, :cover_image), post) ==
               [name: "cover_image", post_id: post.id]
    end

    test "a polymorphic attachment resource uses the record type and id" do
      post = %ConfigurablePost{id: Ash.UUID.generate()}

      assert Owner.keys(target!(ConfigurablePost, :avatar), post) == [
               name: "avatar",
               record_type: AshStorage.Info.record_type(ConfigurablePost),
               record_id: post.id
             ]
    end

    test "the record's id is converted to a string" do
      target = %Target{
        resource: IntegerPost,
        attachment: %AshStorage.AttachmentDefinition{name: :doc, type: :one},
        attachment_resource: IntegerAttachment,
        owner: Owner.new(IntegerPost, IntegerAttachment)
      }

      assert Owner.keys(target, %IntegerPost{id: 42}) == [name: "doc", post_id: "42"]
    end
  end

  test "write_target/2 names the host resource and record" do
    post = %Post{id: Ash.UUID.generate()}

    assert Owner.write_target(target!(Post, :cover_image), post) ==
             %{"resource" => "Elixir.AshStorage.Test.Post", "id" => post.id}
  end

  describe "Pipeline.attachments/4" do
    setup do
      post = Ash.create!(Post, %{title: "rows"})
      {:ok, %{blob: cover}} = Operations.attach(post, :cover_image, "c", filename: "c.txt")
      {:ok, %{blob: one}} = Operations.attach(post, :documents, "1", filename: "1.txt")
      {:ok, %{blob: two}} = Operations.attach(post, :documents, "2", filename: "2.txt")

      %{post: post, cover: cover, one: one, two: two}
    end

    test "returns the rows of that name only, with their blobs", ctx do
      assert {:ok, rows} =
               Pipeline.attachments(ctx.post, target!(Post, :documents), %Scope{})

      assert Enum.sort(Enum.map(rows, & &1.blob.id)) == Enum.sort([ctx.one.id, ctx.two.id])

      assert {:ok, [cover]} =
               Pipeline.attachments(ctx.post, target!(Post, :cover_image), %Scope{})

      assert cover.blob.id == ctx.cover.id
    end

    test "narrows by blob_id", ctx do
      assert {:ok, [row]} =
               Pipeline.attachments(ctx.post, target!(Post, :documents), %Scope{},
                 blob_id: ctx.two.id
               )

      assert row.blob_id == ctx.two.id
    end
  end

  test "Pipeline.link/4 creates the row the attach action creates" do
    post = Ash.create!(ConfigurablePost, %{title: "row"})

    {:ok, %{blob: blob, attachment: attached}} =
      Operations.attach(post, :avatar, "a", filename: "a")

    other = Ash.create!(ConfigurablePost, %{title: "row"})

    assert {:ok, %{attachment: inserted}} =
             Pipeline.link(other, blob, target!(ConfigurablePost, :avatar), %Scope{})

    fields = [:name, :record_type, :blob_id]
    assert Map.take(inserted, fields) == Map.take(attached, fields)
    assert inserted.record_id == other.id
    assert attached.record_id == post.id
  end
end
