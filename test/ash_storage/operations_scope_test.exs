defmodule AshStorage.OperationsScopeTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store
  alias AshStorage.Test.ContextCapturingService, as: Capture

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Blob do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.OperationsScopeTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage.BlobResource]

    ets do
      private? true
    end

    multitenancy do
      strategy :context
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
      domain: AshStorage.OperationsScopeTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage.AttachmentResource]

    ets do
      private? true
    end

    multitenancy do
      strategy :context
    end

    attachment do
      blob_resource(AshStorage.OperationsScopeTest.Blob)
      belongs_to_resource(:post, AshStorage.OperationsScopeTest.Post)
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.OperationsScopeTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    multitenancy do
      strategy :context
    end

    storage do
      service({AshStorage.Test.ContextCapturingService, []})
      blob_resource(AshStorage.OperationsScopeTest.Blob)
      attachment_resource(AshStorage.OperationsScopeTest.Attachment)

      has_one_attached :doc do
        analyzer(AshStorage.Test.TestAnalyzer)
      end

      has_many_attached(:files)
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: []]
    end
  end

  @actor %{id: "scoped-user"}

  setup do
    Store.reset!()
    tenant = Ash.UUID.generate()

    scopes = [
      struct: %AshStorage.Test.Scope{current_user: @actor, current_tenant: tenant},
      map: %{actor: @actor, tenant: tenant}
    ]

    %{tenant: tenant, scopes: scopes, post: Ash.create!(Post, %{}, tenant: tenant)}
  end

  defp seen?(ctx, tenant), do: ctx.actor == @actor and ctx.tenant == tenant

  for kind <- [:struct, :map] do
    describe "with a #{kind} scope" do
      @kind kind

      test "prepare_direct_upload/3", %{scopes: scopes, tenant: tenant} do
        assert {:ok, %{blob: blob}} =
                 Operations.prepare_direct_upload(Post, :doc,
                   filename: "a.txt",
                   scope: scopes[@kind]
                 )

        assert seen?(Capture.captured_direct_upload_context(blob.key), tenant)
        assert {:ok, _} = Ash.get(Blob, blob.id, tenant: tenant)
      end

      test "attach/4", %{scopes: scopes, tenant: tenant, post: post} do
        assert {:ok, %{blob: blob}} =
                 Operations.attach(post, :doc, "a", filename: "a.txt", scope: scopes[@kind])

        assert seen?(Capture.captured_context(blob.key), tenant)
      end

      test "detach/3, detach_all/3 and purge/3", %{scopes: scopes, post: post} do
        scope = scopes[@kind]
        {:ok, %{blob: one}} = Operations.attach(post, :files, "1", filename: "1", scope: scope)
        {:ok, _} = Operations.attach(post, :files, "2", filename: "2", scope: scope)
        {:ok, _} = Operations.attach(post, :doc, "d", filename: "d", scope: scope)

        assert {:ok, [_]} = Operations.detach(post, :files, blob_id: one.id, scope: scope)
        assert {:ok, [_]} = Operations.detach_all(post, :files, scope: scope)
        assert {:ok, [_]} = Operations.purge(post, :doc, scope: scope)
      end

      test "download/2 and stream_download/2", %{scopes: scopes, tenant: tenant, post: post} do
        {:ok, %{blob: blob}} =
          Operations.attach(post, :doc, "bytes", filename: "b.txt", tenant: tenant)

        assert {:ok, "bytes"} = Operations.download(blob, scope: scopes[@kind])
        assert seen?(Capture.captured_download_context(blob.key), tenant)

        Process.delete({Capture, :download, blob.key})

        assert {:ok, stream} = Operations.stream_download(blob, scope: scopes[@kind])
        assert Enum.join(stream) == "bytes"
        assert seen?(Capture.captured_download_context(blob.key), tenant)
      end

      test "run_analyzer/3", %{scopes: scopes, tenant: tenant, post: post} do
        {:ok, %{blob: blob}} =
          Operations.attach(post, :doc, "one\ntwo",
            filename: "a.txt",
            content_type: "text/plain",
            tenant: tenant
          )

        Process.delete({Capture, :download, blob.key})

        assert {:ok, blob} =
                 Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer, scope: scopes[@kind])

        assert blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] == "complete"
        assert seen?(Capture.captured_download_context(blob.key), tenant)
      end
    end
  end

  test "an explicit option wins over the scope's", %{scopes: scopes, tenant: tenant} do
    other = %{id: "explicit"}

    {:ok, %{blob: blob}} =
      Operations.prepare_direct_upload(Post, :doc,
        filename: "a.txt",
        scope: scopes[:struct],
        actor: other
      )

    ctx = Capture.captured_direct_upload_context(blob.key)
    assert ctx.actor == other
    assert ctx.tenant == tenant
  end
end
