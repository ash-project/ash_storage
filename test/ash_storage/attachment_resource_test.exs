defmodule AshStorage.AttachmentResourceTest do
  use ExUnit.Case, async: true

  alias AshStorage.Test.Attachment
  alias AshStorage.Test.IntegerAttachment
  alias AshStorage.Test.MultiAttachment
  alias AshStorage.Test.PolymorphicAttachment

  describe "belongs_to_resource" do
    test "has name attribute" do
      attr = Ash.Resource.Info.attribute(Attachment, :name)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "does not have record_type or record_id" do
      assert Ash.Resource.Info.attribute(Attachment, :record_type) == nil
      assert Ash.Resource.Info.attribute(Attachment, :record_id) == nil
    end

    test "belongs_to blob" do
      rel = Ash.Resource.Info.relationship(Attachment, :blob)
      assert rel.type == :belongs_to
      assert rel.destination == AshStorage.Test.Blob
    end

    test "belongs_to post" do
      rel = Ash.Resource.Info.relationship(Attachment, :post)
      assert rel.type == :belongs_to
      assert rel.destination == AshStorage.Test.Post
    end

    test "create action accepts FK attributes" do
      action = Ash.Resource.Info.action(Attachment, :create)
      assert :post_id in action.accept
      assert :blob_id in action.accept
      assert :name in action.accept
      refute :record_type in action.accept
      refute :record_id in action.accept
    end
  end

  describe "multiple belongs_to_resource" do
    test "has name attribute" do
      attr = Ash.Resource.Info.attribute(MultiAttachment, :name)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "does not have record_type or record_id" do
      assert Ash.Resource.Info.attribute(MultiAttachment, :record_type) == nil
      assert Ash.Resource.Info.attribute(MultiAttachment, :record_id) == nil
    end

    test "belongs_to post with nullable FK" do
      rel = Ash.Resource.Info.relationship(MultiAttachment, :post)
      assert rel.type == :belongs_to
      assert rel.destination == AshStorage.Test.Post
      assert rel.allow_nil? == true
    end

    test "belongs_to comment with nullable FK" do
      rel = Ash.Resource.Info.relationship(MultiAttachment, :comment)
      assert rel.type == :belongs_to
      assert rel.destination == AshStorage.Test.Comment
      assert rel.allow_nil? == true
    end

    test "create action accepts both FK attributes" do
      action = Ash.Resource.Info.action(MultiAttachment, :create)
      assert :post_id in action.accept
      assert :comment_id in action.accept
      assert :blob_id in action.accept
      assert :name in action.accept
    end
  end

  describe "no belongs_to_resource (polymorphic)" do
    test "has name attribute" do
      attr = Ash.Resource.Info.attribute(PolymorphicAttachment, :name)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "has record_type and record_id" do
      attr = Ash.Resource.Info.attribute(PolymorphicAttachment, :record_type)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false

      attr = Ash.Resource.Info.attribute(PolymorphicAttachment, :record_id)
      assert attr.type == Ash.Type.String
      assert attr.allow_nil? == false
    end

    test "no belongs_to relationships besides blob" do
      rels = Ash.Resource.Info.relationships(PolymorphicAttachment)
      assert length(rels) == 1
      assert hd(rels).name == :blob
    end

    test "create action accepts polymorphic attributes" do
      action = Ash.Resource.Info.action(PolymorphicAttachment, :create)
      assert :record_type in action.accept
      assert :record_id in action.accept
      assert :blob_id in action.accept
      assert :name in action.accept
    end
  end

  describe "belongs_to_resource with attribute_type" do
    test "generates FK attribute with the specified type" do
      attr = Ash.Resource.Info.attribute(IntegerAttachment, :post_id)
      assert attr.type == Ash.Type.Integer
    end

    test "defaults to UUID type when attribute_type is not set" do
      attr = Ash.Resource.Info.attribute(Attachment, :post_id)
      assert attr.type == Ash.Type.UUID
    end
  end

  describe "common (all modes)" do
    test "all have read and destroy actions" do
      for resource <- [Attachment, MultiAttachment, PolymorphicAttachment] do
        assert Ash.Resource.Info.action(resource, :read).type == :read
        assert Ash.Resource.Info.action(resource, :destroy).type == :destroy
      end
    end

    test "all belong to blob" do
      for resource <- [Attachment, MultiAttachment, PolymorphicAttachment] do
        rel = Ash.Resource.Info.relationship(resource, :blob)
        assert rel.type == :belongs_to
        assert rel.destination == AshStorage.Test.Blob
        assert rel.allow_nil? == false
      end
    end
  end
end
