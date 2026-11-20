defmodule AshStorage.AttachMatrixPgTest do
  # The Postgres half of `attach_matrix_test.exs`: background jobs, foreign
  # keys and transactions.
  use AshStorage.RepoCase, async: false
  use Oban.Testing, repo: AshStorage.TestRepo

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store
  alias AshStorage.Test.{KnownGap, PgAttachment, PgBlob, PgPost}

  @moduletag :oban

  # Cells that fail today, with the issue that explains them. A listed cell
  # fails the suite once it passes.
  @gaps %{
    {:file_argument, :oban_analyzer} => "#76",
    {:direct_upload, :oban_analyzer} => "#76",
    {:file_argument, :oban_variant} => "#76",
    {:direct_upload, :oban_variant} => "#76",
    {:file_argument, :failed_variant_keeps_old_file} => "#76",
    {:direct_upload, :failed_variant_keeps_old_file} => "#76",
    {:action, :rollback_keeps_old_file} => "#66",
    {:file_argument, :rollback_keeps_old_file} => "#66",
    {:direct_upload, :rollback_keeps_old_file} => "#66",
    {:purge, :rollback_keeps_file} => "#66"
  }

  @entries [:action, :file_argument, :direct_upload]
  @analyzer to_string(AshStorage.Test.TestAnalyzer)

  setup do
    Store.reset!()

    tmp_dir =
      Path.join(System.tmp_dir!(), "ash_storage_matrix_pg_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    Process.put(:matrix_tmp_dir, tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    :ok
  end

  for entry <- @entries do
    describe "through #{entry}" do
      @entry entry

      test "8. an Oban analyzer is marked pending, enqueued, and completes in its job" do
        KnownGap.check(@gaps, {@entry, :oban_analyzer}, fn ->
          {:ok, %{blob: blob}} = attach(@entry, post!(), :report, "one\ntwo")

          blob = Ash.get!(PgBlob, blob.id)
          assert blob.pending_analyzers
          assert blob.analyzers[@analyzer]["status"] == "pending"
          assert_enqueued(worker: PgBlob.RunPendingAnalyzersWorker)

          drain(:run_pending_analyzers)

          blob = Ash.get!(PgBlob, blob.id)
          assert blob.analyzers[@analyzer]["status"] == "complete"
          assert blob.metadata["line_count"] == 2
          refute blob.pending_analyzers
        end)
      end

      test "9. an Oban variant is recorded, enqueued, and generated in its job" do
        KnownGap.check(@gaps, {@entry, :oban_variant}, fn ->
          {:ok, %{blob: blob}} = attach(@entry, post!(), :report, "shout")

          blob = Ash.get!(PgBlob, blob.id)
          assert blob.pending_variants
          assert blob.metadata["__pending_variants__"]["oban_upper"]["status"] == "pending"
          assert_enqueued(worker: PgBlob.RunPendingVariantsWorker)

          drain(:run_pending_variants)

          variants = Ash.load!(blob, :variants).variants
          assert variant = Enum.find(variants, &(&1.variant_name == "oban_upper"))
          assert {:ok, "SHOUT"} = Store.download(variant.key, [])
        end)
      end

      test "19. replacing a blob that has variants succeeds and leaves nothing behind" do
        KnownGap.check(@gaps, {@entry, :replace_removes_variants}, fn ->
          post = post!()
          {:ok, %{blob: old}} = attach(:action, post, :cover_image, "old")
          assert [variant] = Ash.load!(old, :variants).variants

          assert {:ok, _} = attach(@entry, post, :cover_image, "new")

          assert {:error, _} = Ash.get(PgBlob, old.id)
          assert {:error, _} = Ash.get(PgBlob, variant.id)
          refute Store.exists?(old.key)
          refute Store.exists?(variant.key)
        end)
      end

      test "20. a later after_action hook that fails keeps the old rows and file" do
        KnownGap.check(@gaps, {@entry, :failed_hook_keeps_old_file}, fn ->
          post = post!()
          {:ok, %{blob: old}} = attach(:action, post, :cover_image, "old", binary())

          assert {:error, _} =
                   attach(@entry, post, :cover_image, "new", binary() ++ [after_action: &fail/2])

          assert_old_intact(post, :cover_image, old)
        end)
      end

      test "21. a failing eager variant of the new file keeps the old rows and file" do
        KnownGap.check(@gaps, {@entry, :failed_variant_keeps_old_file}, fn ->
          post = post!()
          {:ok, %{blob: old}} = attach(:action, post, :fragile, "old", binary())

          assert {:error, _} = attach(@entry, post, :fragile, "FAIL")

          assert_old_intact(post, :fragile, old)
        end)
      end

      test "22. the caller's transaction rolling back keeps the old file" do
        KnownGap.check(@gaps, {@entry, :rollback_keeps_old_file}, fn ->
          post = post!()
          {:ok, %{blob: old}} = attach(:action, post, :cover_image, "old", binary())

          TestRepo.transaction(fn ->
            {:ok, _} = attach(@entry, post, :cover_image, "new", binary())
            TestRepo.rollback(:undo)
          end)

          assert_old_intact(post, :cover_image, old)
        end)
      end
    end
  end

  describe "removal" do
    test "P1. purge_<name> of a blob with variants succeeds and leaves nothing behind" do
      KnownGap.check(@gaps, {:purge, :removes_variants}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :cover_image, "shout")
        [variant] = Ash.load!(blob, :variants).variants

        assert {:ok, [_]} = Operations.purge(post, :cover_image)

        assert {:error, _} = Ash.get(PgBlob, blob.id)
        assert {:error, _} = Ash.get(PgBlob, variant.id)
        refute Store.exists?(blob.key)
        refute Store.exists?(variant.key)
      end)
    end

    test "P3. a later after_action hook that fails after a purge keeps the rows and file" do
      KnownGap.check(@gaps, {:purge, :failed_hook_keeps_file}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :cover_image, "kept", binary())

        assert {:error, _} =
                 post
                 |> Ash.Changeset.for_update(:purge_cover_image, %{})
                 |> Ash.Changeset.after_action(&fail/2)
                 |> Ash.update()

        assert_old_intact(post, :cover_image, blob)
      end)
    end

    test "P4. the caller's transaction rolling back after a purge keeps the file" do
      KnownGap.check(@gaps, {:purge, :rollback_keeps_file}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :cover_image, "kept", binary())

        TestRepo.transaction(fn ->
          {:ok, [_]} = Operations.purge(post, :cover_image)
          TestRepo.rollback(:undo)
        end)

        assert_old_intact(post, :cover_image, blob)
      end)
    end

    test "P7. an asynchronous host destroy marks the blob, and :purge_blob removes its variants" do
      KnownGap.check(@gaps, {:host_destroy, :removes_variants}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :cover_image, "shout")
        [variant] = Ash.load!(blob, :variants).variants

        Ash.destroy!(post)

        marked = Ash.get!(PgBlob, blob.id)
        assert marked.pending_purge

        assert :ok = Ash.destroy(marked, action: :purge_blob)

        assert {:error, _} = Ash.get(PgBlob, blob.id)
        assert {:error, _} = Ash.get(PgBlob, variant.id)
        refute Store.exists?(blob.key)
        refute Store.exists?(variant.key)
      end)
    end

    test "P8. an asynchronous host destroy does not mark a blob another record uses" do
      KnownGap.check(@gaps, {:host_destroy, :keeps_shared_blob}, fn ->
        post = post!()
        other = post!()
        {:ok, %{blob: shared}} = attach(:action, post, :cover_image, "shared", binary())
        {:ok, _} = attach_blob(other, :cover_image, shared)

        Ash.destroy!(post)

        refute Ash.get!(PgBlob, shared.id).pending_purge
        assert Store.exists?(shared.key)
      end)
    end

    test "P10. :purge_blob keeps the rows when the file cannot be deleted" do
      KnownGap.check(@gaps, {:purge_blob, :delete_fails}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :cover_image, "stuck", binary())
        {:ok, _} = Operations.detach(post, :cover_image)
        blob = Ash.Seed.update!(blob, %{service_name: AshStorage.Test.FailingDeleteService})

        assert {:error, _} = Ash.destroy(blob, action: :purge_blob)

        assert {:ok, _} = Ash.get(PgBlob, blob.id)
        assert Store.exists?(blob.key)
      end)
    end

    test "P11. a purge inside the caller's transaction logs no transaction hook warning" do
      KnownGap.check(@gaps, {:purge, :nested_without_warning}, fn ->
        post = post!()
        {:ok, _} = attach(:action, post, :cover_image, "gone", binary())

        log =
          capture_log(fn ->
            {:ok, {:ok, [_]}} =
              TestRepo.transaction(fn -> Operations.purge(post, :cover_image) end)
          end)

        refute log =~ "after_transaction"
      end)
    end
  end

  # -- Helpers --

  defp post!, do: Ash.create!(PgPost, %{title: "matrix"})

  # Content that no variant of these attachments accepts, so that the old blob
  # has no variant rows for the foreign key to trip over.
  defp binary, do: [content_type: "application/octet-stream"]

  defp fail(_changeset, _record), do: {:error, "a later hook failed"}

  defp drain(trigger) do
    queue = AshOban.Info.oban_trigger(PgBlob, trigger).queue
    assert %{failure: 0} = Oban.drain_queue(queue: queue)
  end

  defp assert_old_intact(post, name, old) do
    assert [%{blob_id: blob_id}] =
             PgAttachment
             |> Ash.Query.filter(post_id == ^post.id and name == ^to_string(name))
             |> Ash.read!()

    assert blob_id == old.id
    assert {:ok, _} = Ash.get(PgBlob, old.id)
    assert Store.exists?(old.key)
  end

  # Attaches `content` to `record` through `entry`; `:after_action` adds a hook
  # that runs after the entry point's own.
  defp attach(entry, record, name, content, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "text/plain")
    filename = "#{name}.txt"

    changeset =
      case entry do
        :action ->
          Ash.Changeset.for_update(record, :"attach_#{name}", %{
            io: content,
            filename: filename,
            content_type: content_type
          })

        :file_argument ->
          Ash.Changeset.for_update(record, :"update_#{name}", %{
            name => upload(filename, content, content_type)
          })

        :direct_upload ->
          blob = direct_upload!(name, filename, content, content_type)

          Ash.Changeset.for_update(record, :"update_#{name}_blob", %{
            :"#{name}_blob_id" => blob.id
          })
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

  defp attach_blob(record, name, blob) do
    record
    |> Ash.Changeset.for_update(:"update_#{name}_blob", %{:"#{name}_blob_id" => blob.id})
    |> Ash.update()
  end

  defp direct_upload!(name, filename, content, content_type) do
    {:ok, %{blob: blob}} =
      Operations.prepare_direct_upload(PgPost, name,
        filename: filename,
        content_type: content_type,
        byte_size: byte_size(content)
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
