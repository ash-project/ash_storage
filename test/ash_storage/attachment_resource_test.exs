defmodule AshStorage.AttachmentResourceTest do
  use ExUnit.Case, async: true

  alias AshStorage.Test.Attachment

  describe "attributes" do
    test "has name attribute" do
      attr = Ash.Resource.Info.attribute(Attachment, :name)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "has record_type attribute" do
      attr = Ash.Resource.Info.attribute(Attachment, :record_type)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "has record_id attribute" do
      attr = Ash.Resource.Info.attribute(Attachment, :record_id)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end
  end

  describe "relationships" do
    test "belongs_to blob" do
      rel = Ash.Resource.Info.relationship(Attachment, :blob)
      assert rel.type == :belongs_to
      assert rel.destination == AshStorage.Test.Blob
    end
  end

  describe "actions" do
    test "has create action" do
      action = Ash.Resource.Info.action(Attachment, :create)
      assert action.type == :create
    end

    test "has read action" do
      action = Ash.Resource.Info.action(Attachment, :read)
      assert action.type == :read
    end

    test "has destroy action" do
      action = Ash.Resource.Info.action(Attachment, :destroy)
      assert action.type == :destroy
    end
  end
end
