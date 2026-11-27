defmodule AshStorage.AuthorizationTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store
  alias AshStorage.Test.{Matrix, MatrixConfig}

  @actor %{id: "user-1"}

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule RecordMarker do
    @moduledoc false
    # Tells the test process whether the change ran with the marker
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      send(self(), {:marker, changeset.resource, changeset.context[:private][:ash_storage?]})
      changeset
    end
  end

  defmodule Probe do
    @moduledoc false
    # A resource that allows nothing but the library's own calls
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private? true
    end

    policies do
      bypass AshStorage.Checks.AshStorageInteraction do
        authorize_if always()
      end
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule ReadProbe do
    @moduledoc false
    # Reads `Probe` with the options Ash derives from the change's context
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, context) do
      send(self(), {:probe, Ash.read(Probe, Ash.Context.to_opts(context))})
      changeset
    end
  end

  # Blob and attachment rows that belong to the library: it may do anything
  # with them, and everyone else may read them only through the host record.
  defmodule GuardedBlob do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshStorage.BlobResource]

    ets do
      private? true
    end

    blob do
    end

    changes do
      change AshStorage.AuthorizationTest.RecordMarker, on: [:create]
      change AshStorage.AuthorizationTest.ReadProbe, on: [:create]
    end

    policies do
      bypass AshStorage.Checks.AshStorageInteraction do
        authorize_if always()
      end

      policy action_type(:read) do
        authorize_if accessing_from(AshStorage.AuthorizationTest.GuardedAttachment, :blob)
        authorize_if accessing_from(AshStorage.AuthorizationTest.GuardedBlob, :variants)
      end
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule GuardedAttachment do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshStorage.AttachmentResource]

    ets do
      private? true
    end

    attachment do
      blob_resource(AshStorage.AuthorizationTest.GuardedBlob)
      belongs_to_resource(:post, AshStorage.AuthorizationTest.GuardedPost)
    end

    policies do
      bypass AshStorage.Checks.AshStorageInteraction do
        authorize_if always()
      end

      policy action_type(:read) do
        authorize_if accessing_from(AshStorage.AuthorizationTest.GuardedPost, :cover)
      end
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule GuardedPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.AuthorizationTest.GuardedBlob)
      attachment_resource(AshStorage.AuthorizationTest.GuardedAttachment)

      has_one_attached :cover do
        variant(:upper, AshStorage.Test.UppercaseVariant, generate: :eager)
      end
    end

    changes do
      change AshStorage.AuthorizationTest.RecordMarker, on: [:create, :update]
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: []]

      update :update_cover do
        require_atomic? false
        argument :cover, :file, allow_nil?: true

        change attach_file(:cover)
      end
    end
  end

  # A blob resource whose metadata is hidden from callers without an actor
  defmodule FieldBlob do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshStorage.BlobResource]

    ets do
      private? true
    end

    blob do
    end

    policies do
      policy always() do
        authorize_if always()
      end
    end

    field_policies do
      field_policy :metadata do
        authorize_if actor_present()
      end

      field_policy :* do
        authorize_if always()
      end
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule FieldAttachment do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage.AttachmentResource]

    ets do
      private? true
    end

    attachment do
      blob_resource(AshStorage.AuthorizationTest.FieldBlob)
      belongs_to_resource(:post, AshStorage.AuthorizationTest.FieldPost)
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule FieldPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.AuthorizationTest.FieldBlob)
      attachment_resource(AshStorage.AuthorizationTest.FieldAttachment)

      has_one_attached :document do
        analyzer(AshStorage.Test.TestAnalyzer)
      end
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: []]
    end
  end

  # Attachment rows that only their post's owner may read
  defmodule OwnedAttachment do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshStorage.AttachmentResource]

    ets do
      private? true
    end

    attachment do
      blob_resource(AshStorage.Test.Blob)
      belongs_to_resource(:post, AshStorage.AuthorizationTest.OwnedPost)
    end

    policies do
      policy action_type(:read) do
        authorize_if expr(post.owner == ^actor(:id))
      end

      policy action_type([:create, :destroy]) do
        authorize_if actor_present()
      end
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule OwnedPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AuthorizationTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.AuthorizationTest.OwnedAttachment)

      has_one_attached :cover do
        variant(:upper, AshStorage.Test.UppercaseVariant, generate: :eager)
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :owner, :string, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, create: [:owner]]

      update :update_cover_blob do
        require_atomic? false
        argument :cover_blob_id, :uuid, allow_nil?: true

        change attach_blob(:cover, argument: :cover_blob_id)
      end
    end
  end

  setup do
    Store.reset!()

    tmp_dir =
      Path.join(System.tmp_dir!(), "ash_storage_authorization_#{System.unique_integer()}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp upload(tmp_dir, content) do
    path = Path.join(tmp_dir, "#{System.unique_integer([:positive])}")
    File.write!(path, content)
    %Plug.Upload{path: path, filename: "file.txt", content_type: "text/plain"}
  end

  defp stored(post, name, opts) do
    post = Ash.load!(post, [{name, :blob}], opts)
    {:ok, content} = Store.download(Map.fetch!(post, name).blob.key, [])
    content
  end

  describe "without the bypass, the caller's actor decides" do
    setup do
      m = MatrixConfig.build(:actor)
      %{m: m, post: Ash.create!(m.post, %{slug: "acceptance"})}
    end

    test "a file argument on an update replaces the file as the action's actor",
         %{m: m, post: post, tmp_dir: tmp_dir} do
      for content <- ["first", "second"] do
        post
        |> Ash.Changeset.for_update(:update_plain, %{plain: upload(tmp_dir, content)},
          actor: @actor
        )
        |> Ash.update!()

        assert stored(post, :plain, m.inspect) == content
      end

      assert [_only_the_replacement] = Store.list_keys()
    end

    test "a file argument without an actor gets the policy's refusal",
         %{post: post, tmp_dir: tmp_dir} do
      assert {:error, %Ash.Error.Forbidden{}} =
               post
               |> Ash.Changeset.for_update(:update_plain, %{plain: upload(tmp_dir, "anon")})
               |> Ash.update()
    end

    test "attach replaces the file as the caller's actor", %{m: m, post: post} do
      for content <- ["first", "second"] do
        assert {:ok, _} =
                 Operations.attach(post, :plain, content, filename: "plain.txt", actor: @actor)

        assert stored(post, :plain, m.inspect) == content
      end

      assert [_only_the_replacement] = Store.list_keys()
    end

    test "attach without an actor gets the policy's refusal", %{post: post} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.attach(post, :plain, "anon", filename: "plain.txt")
    end
  end

  describe "with the bypass and nothing else allowed" do
    setup do
      m = MatrixConfig.build(:deny)
      %{m: m, post: Ash.create!(m.post, %{slug: "deny"}, actor: @actor)}
    end

    test "the host action still needs what its own policies ask for", %{post: post} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Operations.attach(post, :plain, "anon", filename: "plain.txt")

      assert Store.list_keys() == []
    end

    test "the caller cannot read blob and attachment rows directly", %{m: m, post: post} do
      {:ok, %{blob: blob}} =
        Operations.attach(post, :plain, "mine", filename: "plain.txt", actor: @actor)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.get(m.blob, blob.id, actor: @actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(m.attachment, actor: @actor)
    end

    test "a reader's relationship loads are refused", %{m: m, post: post} do
      {:ok, %{record: record, blob: blob, attachment: attachment}} =
        Operations.attach(post, :plain, "mine", filename: "plain.txt", actor: @actor)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.load(post, [plain: :blob], actor: @actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.load(record, :plain, actor: @actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.load(attachment, :blob, actor: @actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.load(blob, :variants, actor: @actor)
      assert Ash.load!(post, [plain: :blob], m.inspect).plain.blob.id == blob.id
    end

    test "prepare_direct_upload/3 creates its blob", %{m: m, post: post} do
      {:ok, %{blob: blob}} =
        Operations.prepare_direct_upload(m.post, :plain,
          filename: "direct.txt",
          actor: @actor
        )

      :ok = Store.upload(blob.key, "direct", AshStorage.Service.Context.new([]))

      assert {:ok, _} =
               post
               |> Ash.Changeset.for_update(:update_plain_blob, %{plain_blob_id: blob.id},
                 actor: @actor
               )
               |> Ash.update()

      assert Ash.load!(post, [plain: :blob], m.inspect).plain.blob.id == blob.id
    end

    test "an on-demand variant is generated for its URL", %{m: m, post: post} do
      {:ok, _} =
        Operations.attach(post, :lazy, "shout",
          filename: "lazy.txt",
          content_type: "text/plain",
          actor: @actor
        )

      post = Ash.load!(post, :lazy_upper_url, actor: @actor)

      assert "http://test.local/storage/" <> _ = post.lazy_upper_url
      assert [_] = Ash.load!(post, [lazy: [blob: :variants]], m.inspect).lazy.blob.variants
    end
  end

  describe "prepare_direct_upload/3 with scope:" do
    for config <- [:actor, :context] do
      test "creates the blob under #{config}" do
        m = MatrixConfig.build(unquote(config))
        caller = Keyword.put_new(m.caller, :actor, @actor)

        scope = %AshStorage.Test.Scope{
          current_user: caller[:actor],
          current_tenant: caller[:tenant]
        }

        assert {:ok, %{blob: blob}} =
                 Operations.prepare_direct_upload(m.post, :plain,
                   filename: "scoped.txt",
                   scope: scope
                 )

        assert {:ok, _} = Ash.get(m.blob, blob.id, m.inspect)
      end
    end
  end

  describe "with rows readable only through the host record" do
    test "the host record loads its file and the rows stay closed" do
      post = Ash.create!(GuardedPost, %{}, actor: @actor)

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover, "hello",
          filename: "cover.txt",
          content_type: "text/plain",
          actor: @actor
        )

      loaded = Ash.load!(post, [cover: [blob: :variants]], actor: @actor)
      assert loaded.cover.blob.id == blob.id
      assert [%{variant_name: "upper"}] = loaded.cover.blob.variants

      assert {:error, %Ash.Error.Forbidden{}} = Ash.get(GuardedBlob, blob.id, actor: @actor)
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(GuardedAttachment, actor: @actor)
    end
  end

  describe "the marker does not leak" do
    test "the host action does not see it, through attach, a file argument, detach and purge",
         %{tmp_dir: tmp_dir} do
      post = Ash.create!(GuardedPost, %{}, actor: @actor)
      assert_received {:marker, GuardedPost, nil}

      {:ok, _} =
        Operations.attach(post, :cover, "one", filename: "cover.txt", actor: @actor)

      assert_received {:marker, GuardedPost, nil}
      refute_received {:marker, GuardedPost, true}
      assert_received {:marker, GuardedBlob, true}

      post
      |> Ash.Changeset.for_update(:update_cover, %{cover: upload(tmp_dir, "two")}, actor: @actor)
      |> Ash.update!()

      assert_received {:marker, GuardedPost, nil}
      refute_received {:marker, GuardedPost, true}
      assert_received {:marker, GuardedBlob, true}

      for remove <- [
            &Operations.detach(&1, :cover, actor: @actor),
            &Operations.detach_all(&1, :cover, actor: @actor),
            &Operations.purge(&1, :cover, actor: @actor)
          ] do
        {:ok, _} = Operations.attach(post, :cover, "again", filename: "c.txt", actor: @actor)
        assert_received {:marker, GuardedPost, nil}

        assert {:ok, [_]} = remove.(post)

        assert_received {:marker, GuardedPost, nil}
        refute_received {:marker, GuardedPost, true}
      end
    end

    test "a change on the blob resource cannot pass it on" do
      post = Ash.create!(GuardedPost, %{}, actor: @actor)

      {:ok, _} =
        Operations.attach(post, :cover, "one", filename: "cover.txt", actor: @actor)

      assert_received {:probe, {:error, %Ash.Error.Forbidden{}}}
    end
  end

  describe "when another owner's rows are hidden from the caller" do
    setup do
      alice = %{id: "alice"}
      bob = %{id: "bob"}

      %{
        alice: alice,
        bob: bob,
        hers: Ash.create!(OwnedPost, %{owner: "alice"}, actor: alice),
        his: Ash.create!(OwnedPost, %{owner: "bob"}, actor: bob)
      }
    end

    test "her purge keeps a blob his record still uses", ctx do
      {:ok, %{blob: shared}} =
        Operations.attach(ctx.hers, :cover, "shared", filename: "s.bin", actor: ctx.alice)

      ctx.his
      |> Ash.Changeset.for_update(:update_cover_blob, %{cover_blob_id: shared.id}, actor: ctx.bob)
      |> Ash.update!()

      assert {:ok, [_]} = Operations.purge(ctx.hers, :cover, actor: ctx.alice)

      assert {:ok, _} = Ash.get(AshStorage.Test.Blob, shared.id)
      assert Store.exists?(shared.key)
      assert Ash.load!(ctx.his, [cover: :blob], actor: ctx.bob).cover.blob.id == shared.id
    end

    test "a replacement of her file keeps a blob his record still uses", ctx do
      {:ok, %{blob: shared}} =
        Operations.attach(ctx.hers, :cover, "shared", filename: "s.bin", actor: ctx.alice)

      ctx.his
      |> Ash.Changeset.for_update(:update_cover_blob, %{cover_blob_id: shared.id}, actor: ctx.bob)
      |> Ash.update!()

      assert {:ok, _} =
               Operations.attach(ctx.hers, :cover, "new", filename: "n.bin", actor: ctx.alice)

      assert {:ok, _} = Ash.get(AshStorage.Test.Blob, shared.id)
      assert Store.exists?(shared.key)
      assert Ash.load!(ctx.his, [cover: :blob], actor: ctx.bob).cover.blob.id == shared.id
    end

    test "her purge keeps a variant his record uses", ctx do
      {:ok, %{blob: source}} =
        Operations.attach(ctx.hers, :cover, "shout",
          filename: "s.txt",
          content_type: "text/plain",
          actor: ctx.alice
        )

      [variant] = Ash.load!(source, :variants).variants

      Ash.create!(
        OwnedAttachment,
        %{name: "cover", post_id: ctx.his.id, blob_id: variant.id},
        authorize?: false
      )

      assert {:ok, [_]} = Operations.purge(ctx.hers, :cover, actor: ctx.alice)

      assert {:ok, _} = Ash.get(AshStorage.Test.Blob, variant.id)
      assert Store.exists?(variant.key)
    end
  end

  test "a field policy that admits the caller lets an eager analyzer write metadata" do
    post = Ash.create!(FieldPost, %{})

    {:ok, %{blob: blob}} =
      Operations.attach(post, :document, "one\ntwo",
        filename: "doc.txt",
        content_type: "text/plain",
        actor: @actor
      )

    assert Ash.get!(FieldBlob, blob.id, authorize?: false).metadata["line_count"] == 2
  end
end
