defmodule AshStorage.AttachMatrixTest do
  # One behaviour per test, run through each way of attaching a file: the
  # generated `attach_<name>` action (`:action`), a file argument
  # (`:file_argument`) and a direct upload (`:direct_upload`).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store
  alias AshStorage.Test.KnownGap

  alias AshStorage.Test.{
    Blob,
    MatrixPost,
    PolicyMatrixBlob,
    PolicyMatrixPost,
    TenantMatrixBlob,
    TenantMatrixPost
  }

  # Cells that fail today, with the issue that explains them. A listed cell
  # fails the suite once it passes.
  @gaps %{
    {:direct_upload, :eager_analyzer} => "#76",
    {:direct_upload, :write_attributes} => "#76",
    {:direct_upload, :failing_analyzer} => "#76",
    {:action, :analyzer_error_reason} => "#94",
    {:file_argument, :analyzer_error_reason} => "#94",
    {:direct_upload, :analyzer_error_reason} => "#76",
    {:file_argument, :eager_variant} => "#76",
    {:direct_upload, :eager_variant} => "#76",
    {:file_argument, :upsert_replaces} => "#76",
    {:file_argument, :scoped_eager_variant} => "#75, #76",
    {:direct_upload, :scoped_eager_variant} => "#76",
    {:action, :replace_removes_variants} => "#88",
    {:file_argument, :replace_removes_variants} => "#88",
    {:direct_upload, :replace_removes_variants} => "#88",
    {:action, :failed_variant_keeps_old_file} => "#66",
    {:file_argument, :failed_variant_keeps_old_file} => "#76",
    {:direct_upload, :failed_variant_keeps_old_file} => "#76",
    {:action, :replace_keeps_shared_blob} => "#67",
    {:file_argument, :replace_keeps_shared_blob} => "#67",
    {:direct_upload, :replace_keeps_shared_blob} => "#67",
    {:action, :raw_plug_upload} => "#103",
    {:direct_upload, :refuses_unattachable_blob} => "#67",
    {:direct_upload, :refuses_foreign_blob} => "#67",
    {:purge, :removes_variants} => "#88",
    {:purge, :keeps_shared_blob} => "#67",
    {:host_destroy, :removes_variants} => "#88",
    {:host_destroy, :keeps_shared_blob} => "#67"
  }

  @entries [:action, :file_argument, :direct_upload]
  @analyzer to_string(AshStorage.Test.TestAnalyzer)
  @failing_analyzer to_string(AshStorage.Test.FailingAnalyzer)

  setup do
    Store.reset!()

    tmp_dir =
      Path.join(System.tmp_dir!(), "ash_storage_matrix_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    Process.put(:matrix_tmp_dir, tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    :ok
  end

  for entry <- @entries do
    describe "through #{entry}" do
      @entry entry

      test "1. stores the blob, the attachment row and the file" do
        KnownGap.check(@gaps, {@entry, :stores}, fn ->
          post = post!()

          assert {:ok, %{record: record, blob: blob, attachment: attachment}} =
                   attach(@entry, post, :plain, "hello")

          assert blob.filename == "plain.txt"
          assert attachment.blob_id == blob.id
          assert Store.exists?(blob.key)
          assert Ash.load!(record, plain: :blob).plain.blob.id == blob.id
        end)
      end

      test "3. an eager analyzer stores its result and completes" do
        KnownGap.check(@gaps, {@entry, :eager_analyzer}, fn ->
          {:ok, %{blob: blob}} = attach(@entry, post!(), :doc, "one\ntwo")

          blob = Ash.get!(Blob, blob.id)
          assert blob.analyzers[@analyzer]["status"] == "complete"
          assert blob.metadata["line_count"] == 2
        end)
      end

      test "4. write_attributes are on the host record after the same write" do
        KnownGap.check(@gaps, {@entry, :write_attributes}, fn ->
          post = post!()
          {:ok, %{record: record}} = attach(@entry, post, :doc, "one\ntwo\nthree")

          assert record.lines == 3
          assert Ash.get!(MatrixPost, post.id).lines == 3
        end)
      end

      test "5. a failing analyzer is marked as error and the attach succeeds" do
        KnownGap.check(@gaps, {@entry, :failing_analyzer}, fn ->
          assert {:ok, %{blob: blob}} = attach(@entry, post!(), :doc, "data")

          blob = Ash.get!(Blob, blob.id)
          assert blob.analyzers[@failing_analyzer]["status"] == "error"
        end)
      end

      test "6. a failing analyzer's reason is on the blob and in the log" do
        KnownGap.check(@gaps, {@entry, :analyzer_error_reason}, fn ->
          post = post!()

          log =
            capture_log(fn ->
              assert {:ok, %{blob: blob}} = attach(@entry, post, :doc, "data")
              send(self(), {:blob, blob})
            end)

          assert_received {:blob, blob}
          blob = Ash.get!(Blob, blob.id)
          assert blob.analyzers[@failing_analyzer]["error"] == ":analysis_failed"
          assert log =~ "FailingAnalyzer"
        end)
      end

      test "7. an eager variant is generated, and skipped when it does not accept the type" do
        KnownGap.check(@gaps, {@entry, :eager_variant}, fn ->
          {:ok, %{blob: blob}} = attach(@entry, post!(), :doc, "shout")

          assert [variant] = Ash.load!(blob, :variants).variants
          assert variant.variant_name == "upper"
          assert {:ok, "SHOUT"} = Store.download(variant.key, [])

          assert {:ok, %{blob: binary}} =
                   attach(@entry, post!(), :doc, "raw", content_type: "application/octet-stream")

          assert [] = Ash.load!(binary, :variants).variants
        end)
      end

      test "10. a has_one on an update loses its old attachment, blob and file" do
        KnownGap.check(@gaps, {@entry, :update_replaces}, fn ->
          post = post!()
          {:ok, %{blob: old}} = attach(@entry, post, :plain, "old")
          {:ok, %{blob: new}} = attach(@entry, post, :plain, "new")

          assert [attachment] = attachments(post, :plain)
          assert attachment.blob_id == new.id
          assert {:error, _} = Ash.get(Blob, old.id)
          refute Store.exists?(old.key)
        end)
      end

      test "12. a has_many appends" do
        KnownGap.check(@gaps, {@entry, :has_many_appends}, fn ->
          post = post!()
          {:ok, %{blob: one}} = attach(@entry, post, :files, "one")
          {:ok, %{blob: two}} = attach(@entry, post, :files, "two")

          assert Enum.sort([one.id, two.id]) ==
                   post |> attachments(:files) |> Enum.map(& &1.blob_id) |> Enum.sort()
        end)
      end

      test "14. context multitenancy: the first file" do
        KnownGap.check(@gaps, {@entry, :tenant_first_file}, fn ->
          scope = [tenant: Ash.UUID.generate()]

          assert {:ok, %{record: post, blob: blob}} =
                   create_with(@entry, TenantMatrixPost, :doc, "hello", scope)

          assert [attachment] = attachments(post, :doc, scope)
          assert attachment.blob_id == blob.id
        end)
      end

      test "15. context multitenancy: an update replaces the file" do
        KnownGap.check(@gaps, {@entry, :tenant_replaces}, fn ->
          tenant = Ash.UUID.generate()
          scope = [tenant: tenant]
          post = Ash.create!(TenantMatrixPost, %{}, scope)

          {:ok, %{blob: old}} = attach(@entry, post, :doc, "old", scope: scope)
          {:ok, %{blob: new}} = attach(@entry, post, :doc, "new", scope: scope)

          assert [%{blob_id: blob_id}] = attachments(post, :doc, scope)
          assert blob_id == new.id
          assert {:error, _} = Ash.get(TenantMatrixBlob, old.id, scope)
          refute Store.exists?(old.key)
        end)
      end

      test "16. policies with an actor: an update replaces the file" do
        KnownGap.check(@gaps, {@entry, :policy_replaces}, fn ->
          scope = [actor: %{id: "actor"}]
          post = Ash.create!(PolicyMatrixPost, %{})

          {:ok, %{blob: old}} = attach(@entry, post, :doc, "old", scope: scope)
          {:ok, %{blob: new}} = attach(@entry, post, :doc, "new", scope: scope)

          assert [%{blob_id: blob_id}] = attachments(post, :doc, scope)
          assert blob_id == new.id
          assert {:error, _} = Ash.get(PolicyMatrixBlob, old.id, scope)
          refute Store.exists?(old.key)
        end)
      end

      test "17. policies, authorize?: false and no actor: an update replaces the file" do
        KnownGap.check(@gaps, {@entry, :unauthorized_replaces}, fn ->
          scope = [authorize?: false]
          post = Ash.create!(PolicyMatrixPost, %{})

          {:ok, %{blob: old}} = attach(@entry, post, :doc, "old", scope: scope)
          {:ok, %{blob: new}} = attach(@entry, post, :doc, "new", scope: scope)

          assert [%{blob_id: blob_id}] = attachments(post, :doc, scope)
          assert blob_id == new.id
          assert {:error, _} = Ash.get(PolicyMatrixBlob, old.id, scope)
          refute Store.exists?(old.key)
        end)
      end

      test "18. an eager variant under multitenancy and under policies" do
        KnownGap.check(@gaps, {@entry, :scoped_eager_variant}, fn ->
          tenant_scope = [tenant: Ash.UUID.generate()]
          post = Ash.create!(TenantMatrixPost, %{}, tenant_scope)

          assert {:ok, %{blob: blob}} =
                   attach(@entry, post, :eager, "shout", scope: tenant_scope)

          assert [%{variant_name: "upper"}] = Ash.load!(blob, :variants, tenant_scope).variants

          actor_scope = [actor: %{id: "actor"}]
          post = Ash.create!(PolicyMatrixPost, %{})

          assert {:ok, %{blob: blob}} = attach(@entry, post, :eager, "shout", scope: actor_scope)
          assert [%{variant_name: "upper"}] = Ash.load!(blob, :variants, actor_scope).variants
        end)
      end

      test "19. replacing a blob that has variants leaves nothing behind" do
        KnownGap.check(@gaps, {@entry, :replace_removes_variants}, fn ->
          post = post!()
          {:ok, %{blob: old}} = attach(:action, post, :doc, "old")
          assert [variant] = Ash.load!(old, :variants).variants

          assert {:ok, _} = attach(@entry, post, :doc, "new")

          assert {:error, _} = Ash.get(Blob, old.id)
          assert {:error, _} = Ash.get(Blob, variant.id)
          refute Store.exists?(old.key)
          refute Store.exists?(variant.key)
        end)
      end

      test "21. a failing eager variant of the new file keeps the old file" do
        KnownGap.check(@gaps, {@entry, :failed_variant_keeps_old_file}, fn ->
          post = post!()

          {:ok, %{blob: old}} =
            attach(:action, post, :fragile, "old", content_type: "application/octet-stream")

          assert {:error, _} = attach(@entry, post, :fragile, "FAIL")
          assert Store.exists?(old.key)
        end)
      end

      test "23. a replaced blob that another record uses survives with its file" do
        KnownGap.check(@gaps, {@entry, :replace_keeps_shared_blob}, fn ->
          post = post!()
          other = post!()
          {:ok, %{blob: shared}} = attach(:action, post, :plain, "shared")
          {:ok, _} = attach_blob(other, :plain, shared)

          assert {:ok, _} = attach(@entry, post, :plain, "new")

          assert {:ok, _} = Ash.get(Blob, shared.id)
          assert Store.exists?(shared.key)
          assert Ash.load!(other, plain: :blob).plain.blob.id == shared.id
        end)
      end
    end
  end

  describe "through file_argument only" do
    test "2. a nil argument attaches nothing" do
      KnownGap.check(@gaps, {:file_argument, :nil_argument}, fn ->
        post = Ash.create!(MatrixPost, %{slug: slug(), doc: nil}, action: :create_with_doc)

        assert Ash.load!(post, :doc).doc == nil
        assert Store.list_keys() == []
      end)
    end

    test "11. a has_one on a create that upserts keeps one attachment row" do
      KnownGap.check(@gaps, {:file_argument, :upsert_replaces}, fn ->
        slug = slug()

        for content <- ["one", "two"] do
          Ash.create!(MatrixPost, %{slug: slug, doc: upload(:doc, content)},
            action: :upsert_with_doc
          )
        end

        post = Ash.get!(MatrixPost, slug: slug)
        assert [_] = attachments(post, :doc)
      end)
    end

    test "25. a bulk create where some inputs have no file" do
      KnownGap.check(@gaps, {:file_argument, :bulk_create}, fn ->
        with_file = slug()
        without_file = slug()

        assert %Ash.BulkResult{status: :success, records: records} =
                 Ash.bulk_create(
                   [%{slug: with_file, doc: upload(:doc, "one")}, %{slug: without_file}],
                   MatrixPost,
                   :create_with_doc,
                   return_records?: true
                 )

        records = Map.new(records, &{&1.slug, Ash.load!(&1, doc: :blob)})
        assert records[with_file].doc.blob.filename == "doc.txt"
        assert records[without_file].doc == nil
      end)
    end
  end

  describe "through direct_upload only" do
    test "2. a nil argument attaches nothing" do
      KnownGap.check(@gaps, {:direct_upload, :nil_argument}, fn ->
        post =
          Ash.create!(MatrixPost, %{slug: slug(), doc_blob_id: nil},
            action: :create_with_doc_blob
          )

        assert Ash.load!(post, :doc).doc == nil
        assert Store.list_keys() == []
      end)
    end

    test "11. a has_one on a create that upserts keeps one attachment row" do
      KnownGap.check(@gaps, {:direct_upload, :upsert_replaces}, fn ->
        slug = slug()

        for content <- ["one", "two"] do
          blob = direct_upload!(MatrixPost, :doc, content)

          Ash.create!(MatrixPost, %{slug: slug, doc_blob_id: blob.id},
            action: :upsert_with_doc_blob
          )
        end

        post = Ash.get!(MatrixPost, slug: slug)
        assert [_] = attachments(post, :doc)
      end)
    end

    test "13. the attached blob sent again changes nothing and asks the service nothing" do
      KnownGap.check(@gaps, {:direct_upload, :resend_attached_blob}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:direct_upload, post, :plain, "hello")

        # Without the object a `head/2` call fails, so success shows there was none
        Store.delete(blob.key, AshStorage.Service.Context.new([]))

        assert {:ok, _} = attach_blob(post, :plain, blob)
        assert [attachment] = attachments(post, :plain)
        assert attachment.blob_id == blob.id
      end)
    end

    test "26. the id of a variant blob, or of a blob marked for purge, is refused" do
      KnownGap.check(@gaps, {:direct_upload, :refuses_unattachable_blob}, fn ->
        {:ok, %{blob: source}} = attach(:action, post!(), :doc, "shout")
        [variant] = Ash.load!(source, :variants).variants

        post = post!()
        assert {:error, _} = attach_blob(post, :plain, variant)

        marked = direct_upload!(MatrixPost, :plain, "marked")
        marked = Ash.Seed.update!(marked, %{pending_purge: true})
        assert {:error, _} = attach_blob(post, :plain, marked)

        assert attachments(post, :plain) == []
      end)
    end

    test "27. the id of a blob attached to another record is refused" do
      KnownGap.check(@gaps, {:direct_upload, :refuses_foreign_blob}, fn ->
        {:ok, %{blob: blob}} = attach(:direct_upload, post!(), :plain, "theirs")

        post = post!()
        assert {:error, _} = attach_blob(post, :plain, blob)
        assert attachments(post, :plain) == []
      end)
    end
  end

  describe "through action only" do
    test "24. a raw %Plug.Upload{} where an eager analyzer accepts the type" do
      KnownGap.check(@gaps, {:action, :raw_plug_upload}, fn ->
        upload = upload(:doc, "one\ntwo")

        assert {:ok, %{blob: blob}} =
                 Operations.attach(post!(), :doc, upload,
                   filename: upload.filename,
                   content_type: upload.content_type
                 )

        assert blob.metadata["line_count"] == 2
      end)
    end
  end

  describe "removal" do
    test "P1. purge_<name> of a blob with variants leaves nothing behind" do
      KnownGap.check(@gaps, {:purge, :removes_variants}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :doc, "shout")
        [variant] = Ash.load!(blob, :variants).variants

        assert {:ok, [_]} = Operations.purge(post, :doc)

        assert {:error, _} = Ash.get(Blob, blob.id)
        assert {:error, _} = Ash.get(Blob, variant.id)
        refute Store.exists?(blob.key)
        refute Store.exists?(variant.key)
      end)
    end

    test "P2. purge_<name> keeps a blob another record uses, and the last purge removes it" do
      KnownGap.check(@gaps, {:purge, :keeps_shared_blob}, fn ->
        post = post!()
        other = post!()
        {:ok, %{blob: shared}} = attach(:action, post, :plain, "shared")
        {:ok, _} = attach_blob(other, :plain, shared)

        assert {:ok, [_]} = Operations.purge(post, :plain)
        assert {:ok, _} = Ash.get(Blob, shared.id)
        assert Store.exists?(shared.key)
        assert Ash.load!(other, plain: :blob).plain.blob.id == shared.id

        assert {:ok, [_]} = Operations.purge(other, :plain)
        assert {:error, _} = Ash.get(Blob, shared.id)
        refute Store.exists?(shared.key)
      end)
    end

    test "P5. purge_<name> when the service cannot delete the file" do
      KnownGap.check(@gaps, {:purge, :delete_fails}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :plain, "stuck")
        Ash.Seed.update!(blob, %{service_name: AshStorage.Test.FailingDeleteService})

        assert {:error, _} = Operations.purge(post, :plain)
      end)
    end

    test "P6. a synchronous host destroy removes variants too" do
      KnownGap.check(@gaps, {:host_destroy, :removes_variants}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :doc, "shout")
        [variant] = Ash.load!(blob, :variants).variants

        Ash.destroy!(post)

        assert {:error, _} = Ash.get(Blob, blob.id)
        assert {:error, _} = Ash.get(Blob, variant.id)
        refute Store.exists?(blob.key)
        refute Store.exists?(variant.key)
      end)
    end

    test "P8. a host destroy keeps a blob another record uses" do
      KnownGap.check(@gaps, {:host_destroy, :keeps_shared_blob}, fn ->
        post = post!()
        other = post!()
        {:ok, %{blob: shared}} = attach(:action, post, :plain, "shared")
        {:ok, _} = attach_blob(other, :plain, shared)

        Ash.destroy!(post)

        assert {:ok, _} = Ash.get(Blob, shared.id)
        assert Store.exists?(shared.key)
      end)
    end

    test "P9. detach_<name> keeps the blob and the file" do
      KnownGap.check(@gaps, {:detach, :keeps_blob}, fn ->
        post = post!()
        {:ok, %{blob: blob}} = attach(:action, post, :plain, "kept")

        assert {:ok, [_]} = Operations.detach(post, :plain)

        assert attachments(post, :plain) == []
        assert {:ok, _} = Ash.get(Blob, blob.id)
        assert Store.exists?(blob.key)
      end)
    end
  end

  # -- Helpers --

  defp slug, do: "post-#{System.unique_integer([:positive])}"

  defp post!, do: Ash.create!(MatrixPost, %{slug: slug()})

  # Attaches `content` to `record` through `entry` and returns the record with
  # the blob and attachment the entry point reported.
  defp attach(entry, record, name, content, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "text/plain")
    scope = Keyword.get(opts, :scope, [])
    filename = "#{name}.txt"

    case entry do
      :action ->
        Operations.attach(
          record,
          name,
          content,
          [filename: filename, content_type: content_type] ++ scope
        )

      :file_argument ->
        record
        |> Ash.Changeset.for_update(
          :"update_#{name}",
          %{name => upload(name, content, content_type)},
          scope
        )
        |> Ash.update()
        |> entry_result(name)

      :direct_upload ->
        blob = direct_upload!(record.__struct__, name, content, content_type, scope)

        record
        |> Ash.Changeset.for_update(
          :"update_#{name}_blob",
          %{:"#{name}_blob_id" => blob.id},
          scope
        )
        |> Ash.update()
        |> entry_result(name)
    end
  end

  defp attach_blob(record, name, blob) do
    record
    |> Ash.Changeset.for_update(:"update_#{name}_blob", %{:"#{name}_blob_id" => blob.id})
    |> Ash.update()
  end

  defp entry_result({:ok, record}, name) do
    {:ok,
     %{
       record: record,
       blob: record.__metadata__[:"#{name}_blob"],
       attachment: record.__metadata__[:"#{name}_attachment"]
     }}
  end

  defp entry_result({:error, _} = error, _name), do: error

  defp direct_upload!(resource, name, content, content_type \\ "text/plain", scope \\ []) do
    {:ok, %{blob: blob}} =
      Operations.prepare_direct_upload(
        resource,
        name,
        [filename: "#{name}.txt", content_type: content_type, byte_size: byte_size(content)] ++
          scope
      )

    :ok = Store.upload(blob.key, content, AshStorage.Service.Context.new([]))
    blob
  end

  defp upload(name, content, content_type \\ "text/plain") do
    path = Path.join(Process.get(:matrix_tmp_dir), "#{System.unique_integer([:positive])}")
    File.write!(path, content)
    %Plug.Upload{path: path, filename: "#{name}.txt", content_type: content_type}
  end

  # Reads the rows directly: loading a has_one relationship hides duplicates.
  defp attachments(post, name, scope \\ []) do
    relationship = Ash.Resource.Info.relationship(post.__struct__, name)

    relationship.destination
    |> Ash.Query.filter(
      ^[{:name, to_string(name)}, {relationship.destination_attribute, post.id}]
    )
    |> Ash.read!(Keyword.put_new(scope, :authorize?, false))
  end

  # Creates a record with its first file. The generated action needs a record,
  # so `:action` creates one and attaches to it.
  defp create_with(:action, resource, name, content, scope) do
    record = Ash.create!(resource, %{}, scope)
    attach(:action, record, name, content, scope: scope)
  end

  defp create_with(:file_argument, resource, name, content, scope) do
    resource
    |> Ash.Changeset.for_create(:"create_with_#{name}", %{name => upload(name, content)}, scope)
    |> Ash.create()
    |> entry_result(name)
  end

  defp create_with(:direct_upload, resource, name, content, scope) do
    blob = direct_upload!(resource, name, content, "text/plain", scope)

    resource
    |> Ash.Changeset.for_create(
      :"create_with_#{name}_blob",
      %{:"#{name}_blob_id" => blob.id},
      scope
    )
    |> Ash.create()
    |> entry_result(name)
  end
end
