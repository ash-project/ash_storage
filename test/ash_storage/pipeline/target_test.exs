defmodule AshStorage.Pipeline.TargetTest do
  use ExUnit.Case, async: false

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Scope, Target}
  alias AshStorage.Service.Disk

  defmodule NoServiceDomain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshStorage.Pipeline.TargetTest.NoServicePost
    end
  end

  defmodule NoServicePost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.Pipeline.TargetTest.NoServiceDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)

      has_one_attached(:avatar)
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  describe "resolve/2" do
    test "a declared attachment" do
      assert {:ok, %Target{} = target} = Pipeline.resolve(AshStorage.Test.Post, :cover_image)

      assert target.resource == AshStorage.Test.Post
      assert target.attachment.name == :cover_image
      assert target.service == {AshStorage.Service.Test, []}
      assert target.blob_resource == AshStorage.Test.Blob
      assert target.attachment_resource == AshStorage.Test.Attachment
    end

    test "an unknown attachment" do
      assert {:error, {:unknown_attachment, :nope}} =
               Pipeline.resolve(AshStorage.Test.Post, :nope)
    end

    test "a resource with no service" do
      assert {:ok, %Target{service: nil} = target} = Pipeline.resolve(NoServicePost, :avatar)

      assert {:error, :no_service_configured} = Target.service_context(target, %Scope{})
    end
  end

  describe "blob_context/3" do
    setup do
      blob = %AshStorage.Test.Blob{
        key: "key",
        service_name: Disk,
        service_opts: %{"root" => "/persisted"}
      }

      target = %Target{
        resource: AshStorage.Test.Post,
        attachment: %AshStorage.AttachmentDefinition{name: :cover_image, type: :one},
        service: {Disk, root: "/live", base_url: "/files"}
      }

      %{blob: blob, target: target, scope: %Scope{actor: :me, tenant: "t"}}
    end

    test "merges the persisted options over the live ones of the same service", ctx do
      context = Target.blob_context(ctx.blob, ctx.scope, ctx.target)

      assert context.service_opts[:root] == "/persisted"
      assert context.service_opts[:base_url] == "/files"
      assert context.resource == AshStorage.Test.Post
      assert {context.actor, context.tenant} == {:me, "t"}
    end

    test "uses the persisted options only for another service", ctx do
      target = %{ctx.target | service: {AshStorage.Service.Test, base_url: "/other"}}
      context = Target.blob_context(ctx.blob, ctx.scope, target)

      assert context.service_opts == Target.persisted_service_opts(ctx.blob)
      refute context.service_opts[:base_url]
    end

    test "uses the persisted options only without a target", ctx do
      context = Target.blob_context(ctx.blob, ctx.scope)

      assert context.service_opts == Target.persisted_service_opts(ctx.blob)
      assert context.resource == nil
      assert {context.actor, context.tenant} == {:me, "t"}
    end
  end

  test "persisted_service_opts/1 equals the calculation's value for a Disk blob" do
    root = Path.join(System.tmp_dir!(), "ash_storage_target_test")

    blob =
      Ash.create!(
        AshStorage.Test.Blob,
        %{
          key: "k",
          filename: "f.txt",
          service_name: Disk,
          service_opts: Target.persistable_service_opts(Disk, root: root, base_url: "/files")
        },
        action: :create
      )

    loaded = Ash.load!(blob, :parsed_service_opts)

    assert loaded.parsed_service_opts == Target.persisted_service_opts(blob)
    assert Target.persisted_service_opts(blob)[:root] == root
  end
end
