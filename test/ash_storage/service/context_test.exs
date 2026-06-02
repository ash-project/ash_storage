defmodule AshStorage.Service.ContextTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.Context

  describe "new/2" do
    test "defaults the new blob-metadata fields to nil" do
      ctx = Context.new([])

      assert ctx.content_type == nil
      assert ctx.filename == nil
    end

    test "accepts :content_type and :filename in extras" do
      ctx = Context.new([], content_type: "image/jpeg", filename: "cover.jpg")

      assert ctx.content_type == "image/jpeg"
      assert ctx.filename == "cover.jpg"
    end
  end

  describe "put_blob_metadata/2" do
    test "sets :content_type while leaving :filename untouched" do
      ctx =
        Context.new([])
        |> Context.put_blob_metadata(content_type: "image/png")

      assert ctx.content_type == "image/png"
      assert ctx.filename == nil
    end

    test "sets :filename while leaving :content_type untouched" do
      ctx =
        Context.new([], content_type: "image/png")
        |> Context.put_blob_metadata(filename: "cover.png")

      assert ctx.content_type == "image/png"
      assert ctx.filename == "cover.png"
    end

    test "preserves unrelated context fields" do
      ctx =
        Context.new([bucket: "b"], actor: :alice, tenant: :acme)
        |> Context.put_expected_md5("MD5MD5MD5MD5MD5MD5MD5MD5")
        |> Context.put_blob_metadata(content_type: "image/gif", filename: "g.gif")

      assert ctx.actor == :alice
      assert ctx.tenant == :acme
      assert ctx.service_opts == [bucket: "b"]
      assert ctx.expected_md5 == "MD5MD5MD5MD5MD5MD5MD5MD5"
      assert ctx.content_type == "image/gif"
      assert ctx.filename == "g.gif"
    end

    test "treats absent keys as no-ops (keeps existing values)" do
      ctx =
        Context.new([], content_type: "image/jpeg", filename: "a.jpg")
        |> Context.put_blob_metadata([])

      assert ctx.content_type == "image/jpeg"
      assert ctx.filename == "a.jpg"
    end
  end
end
