defmodule AshStorage.AttachMatrixPgTest do
  # The Postgres half of `attach_matrix_test.exs`: background jobs, foreign
  # keys and transactions. It runs once over the plain resources and once over
  # resources whose blob and attachment rows allow nothing but AshStorage's and
  # AshOban's own calls, where the jobs run under policies.
  use AshStorage.RepoCase,
    async: false,
    parameterize: [%{config: :plain}, %{config: :deny}]

  use Oban.Testing, repo: AshStorage.TestRepo

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store
  alias AshStorage.Test.{KnownGap, PgAttachment, PgBlob, PgPost}

  @moduletag :oban

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule DenyBlob do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AttachMatrixPgTest.Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshStorage.BlobResource, AshOban]

    postgres do
      table "storage_blobs"
      repo(AshStorage.TestRepo)
    end

    blob do
    end

    policies do
      bypass AshStorage.Checks.AshStorageInteraction do
        authorize_if always()
      end

      bypass AshOban.Checks.AshObanInteraction do
        authorize_if always()
      end
    end

    oban do
      triggers do
        for {name, condition} <- [
              purge_blob: :pending_purge,
              run_pending_variants: :pending_variants,
              run_pending_analyzers: :pending_analyzers
            ] do
          trigger name do
            action name
            read_action :read
            where expr(^ref(condition) == true)
            scheduler_cron("* * * * *")
            max_attempts(3)
            scheduler_module_name(Module.concat(__MODULE__, Macro.camelize("#{name}_scheduler")))
            worker_module_name(Module.concat(__MODULE__, Macro.camelize("#{name}_worker")))
          end
        end
      end
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule DenyAttachment do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AttachMatrixPgTest.Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshStorage.AttachmentResource]

    postgres do
      table "storage_attachments"
      repo(AshStorage.TestRepo)
    end

    attachment do
      blob_resource(AshStorage.AttachMatrixPgTest.DenyBlob)
      belongs_to_resource(:post, AshStorage.AttachMatrixPgTest.DenyPost)
    end

    policies do
      bypass AshStorage.Checks.AshStorageInteraction do
        authorize_if always()
      end
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule DenyPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AttachMatrixPgTest.Domain,
      data_layer: AshPostgres.DataLayer,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshStorage]

    postgres do
      table "posts"
      repo(AshStorage.TestRepo)
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.AttachMatrixPgTest.DenyBlob)
      attachment_resource(AshStorage.AttachMatrixPgTest.DenyAttachment)

      has_one_attached :cover_image do
        variant(:eager_upper, AshStorage.Test.UppercaseVariant, generate: :eager)
        variant(:oban_upper, AshStorage.Test.UppercaseVariant, generate: :oban)
      end

      has_many_attached(:documents, dependent: :detach)

      has_one_attached :report do
        analyzer(AshStorage.Test.TestAnalyzer, analyze: :oban)
        variant(:eager_upper, AshStorage.Test.UppercaseVariant, generate: :eager)
        variant(:oban_upper, AshStorage.Test.UppercaseVariant, generate: :oban)
      end

      has_one_attached :fragile do
        variant(:checked, AshStorage.Test.FailOnMarkerVariant, generate: :eager)
      end
    end

    policies do
      policy always() do
        authorize_if actor_present()
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, allow_nil?: false, public?: true
    end

    actions do
      defaults [:read, :destroy, create: [:title], update: [:title]]

      for name <- [:cover_image, :report, :fragile] do
        update :"update_#{name}" do
          require_atomic? false
          argument name, :file, allow_nil?: true

          change attach_file(name)
        end

        update :"update_#{name}_blob" do
          require_atomic? false
          argument :"#{name}_blob_id", :uuid, allow_nil?: true

          change attach_blob(name, argument: :"#{name}_blob_id")
        end
      end
    end
  end

  # Cells that fail today, with the issue that explains them. A listed cell
  # fails the suite once it passes.
  @gaps %{
    {:action, :rollback_keeps_old_file} => "#66",
    {:file_argument, :rollback_keeps_old_file} => "#66",
    {:direct_upload, :rollback_keeps_old_file} => "#66",
    {:purge, :rollback_keeps_file} => "#66"
  }

  @entries [:action, :file_argument, :direct_upload]
  @analyzer to_string(AshStorage.Test.TestAnalyzer)

  setup %{config: config} do
    Store.reset!()

    tmp_dir =
      Path.join(System.tmp_dir!(), "ash_storage_matrix_pg_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    Process.put(:matrix_tmp_dir, tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{m: configuration(config)}
  end

  defp configuration(:plain),
    do: %{post: PgPost, blob: PgBlob, attachment: PgAttachment, caller: [], inspect: []}

  defp configuration(:deny) do
    %{
      post: DenyPost,
      blob: DenyBlob,
      attachment: DenyAttachment,
      caller: [actor: %{id: "actor"}],
      inspect: [authorize?: false]
    }
  end

  for entry <- @entries do
    describe "through #{entry}" do
      @entry entry

      test "8. an Oban analyzer is marked pending, enqueued, and completes in its job", %{m: m} do
        KnownGap.check(@gaps, {@entry, :oban_analyzer}, fn ->
          {:ok, %{blob: blob}} = attach(m, @entry, post!(m), :report, "one\ntwo")

          blob = Ash.get!(m.blob, blob.id, m.inspect)
          assert blob.pending_analyzers
          assert blob.analyzers[@analyzer]["status"] == "pending"
          assert_enqueued(worker: worker(m, :run_pending_analyzers))

          drain(m, :run_pending_analyzers)

          blob = Ash.get!(m.blob, blob.id, m.inspect)
          assert blob.analyzers[@analyzer]["status"] == "complete"
          assert blob.metadata["line_count"] == 2
          refute blob.pending_analyzers
        end)
      end

      test "9. an Oban variant is recorded, enqueued, and generated in its job", %{m: m} do
        KnownGap.check(@gaps, {@entry, :oban_variant}, fn ->
          {:ok, %{blob: blob}} = attach(m, @entry, post!(m), :report, "shout")

          blob = Ash.get!(m.blob, blob.id, m.inspect)
          assert blob.pending_variants
          assert blob.metadata["__pending_variants__"]["oban_upper"]["status"] == "pending"
          assert_enqueued(worker: worker(m, :run_pending_variants))

          drain(m, :run_pending_variants)

          variants = Ash.load!(blob, :variants, m.inspect).variants
          assert variant = Enum.find(variants, &(&1.variant_name == "oban_upper"))
          assert {:ok, "SHOUT"} = Store.download(variant.key, [])
        end)
      end

      test "19. replacing a blob that has variants succeeds and leaves nothing behind", %{m: m} do
        KnownGap.check(@gaps, {@entry, :replace_removes_variants}, fn ->
          post = post!(m)
          {:ok, %{blob: old}} = attach(m, :action, post, :cover_image, "old")
          assert [variant] = Ash.load!(old, :variants, m.inspect).variants

          assert {:ok, _} = attach(m, @entry, post, :cover_image, "new")

          assert {:error, _} = Ash.get(m.blob, old.id, m.inspect)
          assert {:error, _} = Ash.get(m.blob, variant.id, m.inspect)
          refute Store.exists?(old.key)
          refute Store.exists?(variant.key)
        end)
      end

      test "20. a later after_action hook that fails keeps the old rows and file", %{m: m} do
        KnownGap.check(@gaps, {@entry, :failed_hook_keeps_old_file}, fn ->
          post = post!(m)
          {:ok, %{blob: old}} = attach(m, :action, post, :cover_image, "old", binary())

          assert {:error, _} =
                   attach(
                     m,
                     @entry,
                     post,
                     :cover_image,
                     "new",
                     binary() ++ [after_action: &fail/2]
                   )

          assert_old_intact(m, post, :cover_image, old)
        end)
      end

      test "21. a failing eager variant of the new file keeps the old rows and file", %{m: m} do
        KnownGap.check(@gaps, {@entry, :failed_variant_keeps_old_file}, fn ->
          post = post!(m)
          {:ok, %{blob: old}} = attach(m, :action, post, :fragile, "old", binary())

          assert {:error, _} = attach(m, @entry, post, :fragile, "FAIL")

          assert_old_intact(m, post, :fragile, old)
        end)
      end

      test "22. the caller's transaction rolling back keeps the old file", %{m: m} do
        KnownGap.check(@gaps, {@entry, :rollback_keeps_old_file}, fn ->
          post = post!(m)
          {:ok, %{blob: old}} = attach(m, :action, post, :cover_image, "old", binary())

          TestRepo.transaction(fn ->
            {:ok, _} = attach(m, @entry, post, :cover_image, "new", binary())
            TestRepo.rollback(:undo)
          end)

          assert_old_intact(m, post, :cover_image, old)
        end)
      end
    end
  end

  describe "removal" do
    test "P1. purge_<name> of a blob with variants succeeds and leaves nothing behind", %{m: m} do
      KnownGap.check(@gaps, {:purge, :removes_variants}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :cover_image, "shout")
        [variant] = Ash.load!(blob, :variants, m.inspect).variants

        assert {:ok, [_]} = Operations.purge(post, :cover_image, m.caller)

        assert {:error, _} = Ash.get(m.blob, blob.id, m.inspect)
        assert {:error, _} = Ash.get(m.blob, variant.id, m.inspect)
        refute Store.exists?(blob.key)
        refute Store.exists?(variant.key)
      end)
    end

    test "P3. a later after_action hook that fails after a purge keeps the rows and file", %{m: m} do
      KnownGap.check(@gaps, {:purge, :failed_hook_keeps_file}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :cover_image, "kept", binary())

        assert {:error, _} =
                 post
                 |> Ash.Changeset.for_update(:purge_cover_image, %{}, m.caller)
                 |> Ash.Changeset.after_action(&fail/2)
                 |> Ash.update()

        assert_old_intact(m, post, :cover_image, blob)
      end)
    end

    test "P4. the caller's transaction rolling back after a purge keeps the file", %{m: m} do
      KnownGap.check(@gaps, {:purge, :rollback_keeps_file}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :cover_image, "kept", binary())

        TestRepo.transaction(fn ->
          {:ok, [_]} = Operations.purge(post, :cover_image, m.caller)
          TestRepo.rollback(:undo)
        end)

        assert_old_intact(m, post, :cover_image, blob)
      end)
    end

    test "P7. an asynchronous host destroy marks the blob, and :purge_blob removes its variants",
         %{m: m} do
      KnownGap.check(@gaps, {:host_destroy, :removes_variants}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :cover_image, "shout")
        [variant] = Ash.load!(blob, :variants, m.inspect).variants

        Ash.destroy!(post, m.caller)

        marked = Ash.get!(m.blob, blob.id, m.inspect)
        assert marked.pending_purge

        assert_enqueued(worker: worker(m, :purge_blob))
        drain(m, :purge_blob)

        assert {:error, _} = Ash.get(m.blob, blob.id, m.inspect)
        assert {:error, _} = Ash.get(m.blob, variant.id, m.inspect)
        refute Store.exists?(blob.key)
        refute Store.exists?(variant.key)
      end)
    end

    test "P8. an asynchronous host destroy does not mark a blob another record uses", %{m: m} do
      KnownGap.check(@gaps, {:host_destroy, :keeps_shared_blob}, fn ->
        post = post!(m)
        other = post!(m)
        {:ok, %{blob: shared}} = attach(m, :action, post, :cover_image, "shared", binary())
        {:ok, _} = attach_blob(m, other, :cover_image, shared)

        Ash.destroy!(post, m.caller)

        refute Ash.get!(m.blob, shared.id, m.inspect).pending_purge
        assert Store.exists?(shared.key)
      end)
    end

    test "P10. :purge_blob keeps the rows when the file cannot be deleted", %{m: m} do
      KnownGap.check(@gaps, {:purge_blob, :delete_fails}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :cover_image, "stuck", binary())
        {:ok, _} = Operations.detach(post, :cover_image, m.caller)

        blob =
          Ash.Seed.update!(blob, %{
            service_name: AshStorage.Test.FailingDeleteService,
            pending_purge: true
          })

        AshOban.run_trigger(blob, :purge_blob)
        queue = AshOban.Info.oban_trigger(m.blob, :purge_blob).queue
        assert %{failure: 1} = Oban.drain_queue(queue: queue)

        assert {:ok, _} = Ash.get(m.blob, blob.id, m.inspect)
        assert Store.exists?(blob.key)

        # The retry, once the file can be deleted, removes both
        Ash.Seed.update!(blob, %{service_name: AshStorage.Service.Test})
        assert %{success: 1} = Oban.drain_queue(queue: queue, with_scheduled: true)
        assert {:error, _} = Ash.get(m.blob, blob.id, m.inspect)
        refute Store.exists?(blob.key)
      end)
    end

    test "P11. a purge inside the caller's transaction logs no transaction hook warning", %{m: m} do
      KnownGap.check(@gaps, {:purge, :nested_without_warning}, fn ->
        post = post!(m)
        {:ok, _} = attach(m, :action, post, :cover_image, "gone", binary())

        log =
          capture_log(fn ->
            {:ok, {:ok, [_]}} =
              TestRepo.transaction(fn -> Operations.purge(post, :cover_image, m.caller) end)
          end)

        refute log =~ "after_transaction"
      end)
    end
  end

  # -- Helpers --

  defp post!(m), do: Ash.create!(m.post, %{title: "matrix"}, m.caller)

  # Content that no variant of these attachments accepts, so that the old blob
  # has no variant rows for the foreign key to trip over.
  defp binary, do: [content_type: "application/octet-stream"]

  defp fail(_changeset, _record), do: {:error, "a later hook failed"}

  defp worker(m, trigger), do: AshOban.Info.oban_trigger(m.blob, trigger).worker

  defp drain(m, trigger) do
    queue = AshOban.Info.oban_trigger(m.blob, trigger).queue
    assert %{failure: 0} = Oban.drain_queue(queue: queue)
  end

  defp assert_old_intact(m, post, name, old) do
    assert [%{blob_id: blob_id}] =
             m.attachment
             |> Ash.Query.filter(post_id == ^post.id and name == ^to_string(name))
             |> Ash.read!(m.inspect)

    assert blob_id == old.id
    assert {:ok, _} = Ash.get(m.blob, old.id, m.inspect)
    assert Store.exists?(old.key)
  end

  # Attaches `content` to `record` through `entry`; `:after_action` adds a hook
  # that runs after the entry point's own.
  defp attach(m, entry, record, name, content, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "text/plain")
    filename = "#{name}.txt"

    changeset =
      case entry do
        :action ->
          Ash.Changeset.for_update(
            record,
            :"attach_#{name}",
            %{io: content, filename: filename, content_type: content_type},
            m.caller
          )

        :file_argument ->
          Ash.Changeset.for_update(
            record,
            :"update_#{name}",
            %{name => upload(filename, content, content_type)},
            m.caller
          )

        :direct_upload ->
          blob = direct_upload!(m, name, filename, content, content_type)

          Ash.Changeset.for_update(
            record,
            :"update_#{name}_blob",
            %{:"#{name}_blob_id" => blob.id},
            m.caller
          )
      end

    changeset =
      case opts[:after_action] do
        nil -> changeset
        hook -> Ash.Changeset.after_action(changeset, hook)
      end

    with {:ok, record} <- Ash.update(changeset) do
      {blob_key, attachment_key} =
        if entry == :action,
          do: {:blob, :attachment},
          else: {:"#{name}_blob", :"#{name}_attachment"}

      {:ok,
       %{
         record: record,
         blob: record.__metadata__[blob_key],
         attachment: record.__metadata__[attachment_key]
       }}
    end
  end

  defp attach_blob(m, record, name, blob) do
    record
    |> Ash.Changeset.for_update(
      :"update_#{name}_blob",
      %{:"#{name}_blob_id" => blob.id},
      m.caller
    )
    |> Ash.update()
  end

  defp direct_upload!(m, name, filename, content, content_type) do
    {:ok, %{blob: blob}} =
      Operations.prepare_direct_upload(
        m.post,
        name,
        [filename: filename, content_type: content_type, byte_size: byte_size(content)] ++
          m.caller
      )

    :ok = Store.upload(blob.key, content, AshStorage.Service.Context.new([]))
    blob
  end

  defp upload(filename, content, content_type) do
    path = Path.join(Process.get(:matrix_tmp_dir), "#{System.unique_integer([:positive])}")
    File.write!(path, content)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end
end
