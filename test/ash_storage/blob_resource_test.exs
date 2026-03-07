defmodule AshStorage.BlobResourceTest do
  use ExUnit.Case, async: true

  alias AshStorage.Test.Blob

  describe "attributes" do
    test "has key attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :key)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "has filename attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :filename)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "has content_type attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :content_type)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == true
    end

    test "has byte_size attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :byte_size)
      assert attr.type == Ash.Type.Integer
      assert attr.allow_nil? == false
    end

    test "has checksum attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :checksum)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "has service_name attribute" do
      attr = Ash.Resource.Info.attribute(Blob, :service_name)
      assert attr.type == Ash.Type.Atom
      assert attr.allow_nil? == false
    end

    test "has metadata attribute with default" do
      attr = Ash.Resource.Info.attribute(Blob, :metadata)
      assert attr.type == Ash.Type.Map
      assert attr.default == %{}
    end
  end

  describe "actions" do
    test "has create action" do
      action = Ash.Resource.Info.action(Blob, :create)
      assert action.type == :create
    end

    test "has read action" do
      action = Ash.Resource.Info.action(Blob, :read)
      assert action.type == :read
    end

    test "has destroy action" do
      action = Ash.Resource.Info.action(Blob, :destroy)
      assert action.type == :destroy
    end

    test "has update_metadata action" do
      action = Ash.Resource.Info.action(Blob, :update_metadata)
      assert action.type == :update
      assert :metadata in action.accept
    end
  end
end
