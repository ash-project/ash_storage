defmodule AshStorage.AttachMatrixTest do
  # One behaviour per test, run through each way of attaching a file: the
  # generated `attach_<name>` action (`:action`), a file argument
  # (`:file_argument`) and a direct upload (`:direct_upload`). The whole matrix
  # runs once per resource configuration in `AshStorage.Test.MatrixConfig`.
  use ExUnit.Case,
    async: false,
    parameterize: Enum.map(AshStorage.Test.MatrixConfig.names(), &%{config: &1})

  import ExUnit.CaptureLog

  require Ash.Query

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store
  alias AshStorage.Test.{KnownGap, MatrixConfig}

  # Cells that fail today under every configuration, with the issue that
  # explains them. A listed cell fails the suite once it passes.
  @gaps %{
    {:direct_upload, :refuses_foreign_blob} => "#67"
  }

  @entries [:action, :file_argument, :direct_upload]
  @analyzer to_string(AshStorage.Test.TestAnalyzer)
  @failing_analyzer to_string(AshStorage.Test.FailingAnalyzer)

  setup %{config: config} do
    Store.reset!()

    tmp_dir =
      Path.join(System.tmp_dir!(), "ash_storage_matrix_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    Process.put(:matrix_tmp_dir, tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{m: MatrixConfig.build(config)}
  end

  for entry <- @entries do
    describe "through #{entry}" do
      @entry entry

      test "1. stores the blob, the attachment row and the file", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :stores}, fn ->
          post = post!(m)

          assert {:ok, %{record: record, blob: blob, attachment: attachment}} =
                   attach(m, @entry, post, :plain, "hello")

          assert blob.filename == "plain.txt"
          assert attachment.blob_id == blob.id
          assert Store.exists?(blob.key)
          assert Ash.load!(record, [plain: :blob], m.inspect).plain.blob.id == blob.id
        end)
      end

      test "3. an eager analyzer stores its result and completes", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :eager_analyzer}, fn ->
          {:ok, %{blob: blob}} = attach(m, @entry, post!(m), :doc, "one\ntwo")

          blob = Ash.get!(m.blob, blob.id, m.inspect)
          assert blob.analyzers[@analyzer]["status"] == "complete"
          assert blob.metadata["line_count"] == 2
        end)
      end

      test "4. write_attributes are on the host record after the same write", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :write_attributes}, fn ->
          post = post!(m)
          {:ok, %{record: record}} = attach(m, @entry, post, :doc, "one\ntwo\nthree")

          assert record.lines == 3
          assert Ash.get!(m.post, post.id, m.inspect).lines == 3
        end)
      end

      test "5. a failing analyzer is marked as error and the attach succeeds", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :failing_analyzer}, fn ->
          assert {:ok, %{blob: blob}} = attach(m, @entry, post!(m), :doc, "data")

          blob = Ash.get!(m.blob, blob.id, m.inspect)
          assert blob.analyzers[@failing_analyzer]["status"] == "error"
        end)
      end

      test "6. a failing analyzer's reason is on the blob and in the log", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :analyzer_error_reason}, fn ->
          post = post!(m)

          log =
            capture_log(fn ->
              assert {:ok, %{blob: blob}} = attach(m, @entry, post, :doc, "data")
              send(self(), {:blob, blob})
            end)

          assert_received {:blob, blob}
          blob = Ash.get!(m.blob, blob.id, m.inspect)
          assert blob.analyzers[@failing_analyzer]["error"] == ":analysis_failed"
          assert log =~ "FailingAnalyzer"
        end)
      end

      test "7. an eager variant is generated, and skipped when it does not accept the type", %{
        m: m
      } do
        KnownGap.check(gaps(m), {@entry, :eager_variant}, fn ->
          {:ok, %{blob: blob}} = attach(m, @entry, post!(m), :doc, "shout")

          assert [variant] = Ash.load!(blob, :variants, m.inspect).variants
          assert variant.variant_name == "upper"
          assert {:ok, "SHOUT"} = Store.download(variant.key, [])

          assert {:ok, %{blob: binary}} =
                   attach(m, @entry, post!(m), :doc, "raw",
                     content_type: "application/octet-stream"
                   )

          assert [] = Ash.load!(binary, :variants, m.inspect).variants
        end)
      end

      test "10. a has_one on an update loses its old attachment, blob and file", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :update_replaces}, fn ->
          post = post!(m)
          {:ok, %{blob: old}} = attach(m, @entry, post, :plain, "old")
          {:ok, %{blob: new}} = attach(m, @entry, post, :plain, "new")

          assert [attachment] = attachments(m, post, :plain)
          assert attachment.blob_id == new.id
          assert {:error, _} = Ash.get(m.blob, old.id, m.inspect)
          refute Store.exists?(old.key)
        end)
      end

      test "12. a has_many appends", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :has_many_appends}, fn ->
          post = post!(m)
          {:ok, %{blob: one}} = attach(m, @entry, post, :files, "one")
          {:ok, %{blob: two}} = attach(m, @entry, post, :files, "two")

          assert Enum.sort([one.id, two.id]) ==
                   m |> attachments(post, :files) |> Enum.map(& &1.blob_id) |> Enum.sort()
        end)
      end

      test "14. a create with its first file puts the blob and attachment on the result",
           %{m: m} do
        KnownGap.check(gaps(m), {@entry, :create_first_file}, fn ->
          assert {:ok, %{record: post, blob: blob, attachment: attachment}} =
                   create_with(m, @entry, "hello")

          assert attachment.blob_id == blob.id
          assert Store.exists?(blob.key)
          assert [row] = attachments(m, post, :doc)
          assert row.id == attachment.id
        end)
      end

      test "19. replacing a blob that has variants leaves nothing behind", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :replace_removes_variants}, fn ->
          post = post!(m)
          {:ok, %{blob: old}} = attach(m, :action, post, :doc, "old")
          assert [variant] = Ash.load!(old, :variants, m.inspect).variants

          assert {:ok, _} = attach(m, @entry, post, :doc, "new")

          assert {:error, _} = Ash.get(m.blob, old.id, m.inspect)
          assert {:error, _} = Ash.get(m.blob, variant.id, m.inspect)
          refute Store.exists?(old.key)
          refute Store.exists?(variant.key)
        end)
      end

      test "21. a failing eager variant of the new file keeps the old file", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :failed_variant_keeps_old_file}, fn ->
          post = post!(m)

          {:ok, %{blob: old}} =
            attach(m, :action, post, :fragile, "old", content_type: "application/octet-stream")

          assert {:error, _} = attach(m, @entry, post, :fragile, "FAIL")
          assert Store.exists?(old.key)
        end)
      end

      test "23. a replaced blob that another record uses survives with its file", %{m: m} do
        KnownGap.check(gaps(m), {@entry, :replace_keeps_shared_blob}, fn ->
          post = post!(m)
          other = post!(m)
          {:ok, %{blob: shared}} = attach(m, :action, post, :plain, "shared")
          {:ok, _} = attach_blob(m, other, :plain, shared)

          assert {:ok, _} = attach(m, @entry, post, :plain, "new")

          assert {:ok, _} = Ash.get(m.blob, shared.id, m.inspect)
          assert Store.exists?(shared.key)
          assert Ash.load!(other, [plain: :blob], m.inspect).plain.blob.id == shared.id
        end)
      end
    end
  end

  describe "through file_argument only" do
    test "2. a nil argument attaches nothing", %{m: m} do
      KnownGap.check(gaps(m), {:file_argument, :nil_argument}, fn ->
        post =
          Ash.create!(m.post, %{slug: slug(), doc: nil}, [action: :create_with_doc] ++ m.caller)

        assert Ash.load!(post, :doc, m.inspect).doc == nil
        assert Store.list_keys() == []
      end)
    end

    test "11. a has_one on a create that upserts keeps one attachment row", %{m: m} do
      KnownGap.check(gaps(m), {:file_argument, :upsert_replaces}, fn ->
        slug = slug()

        for content <- ["one", "two"] do
          Ash.create!(
            m.post,
            %{slug: slug, doc: upload(:doc, content)},
            [action: :upsert_with_doc] ++ m.caller
          )
        end

        post = Ash.get!(m.post, [slug: slug], m.inspect)
        assert [_] = attachments(m, post, :doc)
      end)
    end

    test "25. a bulk create where some inputs have no file", %{m: m} do
      KnownGap.check(gaps(m), {:file_argument, :bulk_create}, fn ->
        with_file = slug()
        without_file = slug()

        assert %Ash.BulkResult{status: :success, records: records} =
                 Ash.bulk_create(
                   [%{slug: with_file, doc: upload(:doc, "one")}, %{slug: without_file}],
                   m.post,
                   :create_with_doc,
                   [return_records?: true] ++ m.caller
                 )

        records = Map.new(records, &{&1.slug, Ash.load!(&1, [doc: :blob], m.inspect)})
        assert records[with_file].doc.blob.filename == "doc.txt"
        assert records[without_file].doc == nil
      end)
    end
  end

  describe "through direct_upload only" do
    test "2. a nil argument attaches nothing", %{m: m} do
      KnownGap.check(gaps(m), {:direct_upload, :nil_argument}, fn ->
        post =
          Ash.create!(
            m.post,
            %{slug: slug(), doc_blob_id: nil},
            [action: :create_with_doc_blob] ++ m.caller
          )

        assert Ash.load!(post, :doc, m.inspect).doc == nil
        assert Store.list_keys() == []
      end)
    end

    test "11. a has_one on a create that upserts keeps one attachment row", %{m: m} do
      KnownGap.check(gaps(m), {:direct_upload, :upsert_replaces}, fn ->
        slug = slug()

        for content <- ["one", "two"] do
          blob = direct_upload!(m, :doc, content)

          Ash.create!(
            m.post,
            %{slug: slug, doc_blob_id: blob.id},
            [action: :upsert_with_doc_blob] ++ m.caller
          )
        end

        post = Ash.get!(m.post, [slug: slug], m.inspect)
        assert [_] = attachments(m, post, :doc)
      end)
    end

    test "13. the attached blob sent again changes nothing and asks the service nothing", %{m: m} do
      KnownGap.check(gaps(m), {:direct_upload, :resend_attached_blob}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :direct_upload, post, :plain, "hello")

        # Without the object a `head/2` call fails, so success shows there was none
        Store.delete(blob.key, AshStorage.Service.Context.new([]))

        assert {:ok, _} = attach_blob(m, post, :plain, blob)
        assert [attachment] = attachments(m, post, :plain)
        assert attachment.blob_id == blob.id
      end)
    end

    test "26. the id of a variant blob, or of a blob marked for purge, is refused", %{m: m} do
      KnownGap.check(gaps(m), {:direct_upload, :refuses_unattachable_blob}, fn ->
        {:ok, %{blob: source}} = attach(m, :action, post!(m), :doc, "shout")
        [variant] = Ash.load!(source, :variants, m.inspect).variants

        post = post!(m)
        assert {:error, _} = attach_blob(m, post, :plain, variant)

        marked = direct_upload!(m, :plain, "marked")
        marked = Ash.Seed.update!(marked, %{pending_purge: true})
        assert {:error, _} = attach_blob(m, post, :plain, marked)

        assert attachments(m, post, :plain) == []
      end)
    end

    test "27. the id of a blob attached to another record is refused", %{m: m} do
      KnownGap.check(gaps(m), {:direct_upload, :refuses_foreign_blob}, fn ->
        {:ok, %{blob: blob}} = attach(m, :direct_upload, post!(m), :plain, "theirs")

        post = post!(m)
        assert {:error, _} = attach_blob(m, post, :plain, blob)
        assert attachments(m, post, :plain) == []
      end)
    end
  end

  describe "through action only" do
    test "24. a raw %Plug.Upload{} where an eager analyzer accepts the type", %{m: m} do
      KnownGap.check(gaps(m), {:action, :raw_plug_upload}, fn ->
        upload = upload(:doc, "one\ntwo")

        assert {:ok, %{blob: blob}} =
                 Operations.attach(
                   post!(m),
                   :doc,
                   upload,
                   [filename: upload.filename, content_type: upload.content_type] ++ m.caller
                 )

        assert blob.metadata["line_count"] == 2
      end)
    end
  end

  describe "removal" do
    test "P1. purge_<name> of a blob with variants leaves nothing behind", %{m: m} do
      KnownGap.check(gaps(m), {:purge, :removes_variants}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :doc, "shout")
        [variant] = Ash.load!(blob, :variants, m.inspect).variants

        assert {:ok, [_]} = Operations.purge(post, :doc, m.caller)

        assert {:error, _} = Ash.get(m.blob, blob.id, m.inspect)
        assert {:error, _} = Ash.get(m.blob, variant.id, m.inspect)
        refute Store.exists?(blob.key)
        refute Store.exists?(variant.key)
      end)
    end

    test "P2. purge_<name> keeps a blob another record uses, and the last purge removes it", %{
      m: m
    } do
      KnownGap.check(gaps(m), {:purge, :keeps_shared_blob}, fn ->
        post = post!(m)
        other = post!(m)
        {:ok, %{blob: shared}} = attach(m, :action, post, :plain, "shared")
        {:ok, _} = attach_blob(m, other, :plain, shared)

        assert {:ok, [_]} = Operations.purge(post, :plain, m.caller)
        assert {:ok, _} = Ash.get(m.blob, shared.id, m.inspect)
        assert Store.exists?(shared.key)
        assert Ash.load!(other, [plain: :blob], m.inspect).plain.blob.id == shared.id

        assert {:ok, [_]} = Operations.purge(other, :plain, m.caller)
        assert {:error, _} = Ash.get(m.blob, shared.id, m.inspect)
        refute Store.exists?(shared.key)
      end)
    end

    test "P5. purge_<name> when the service cannot delete the file", %{m: m} do
      KnownGap.check(gaps(m), {:purge, :delete_fails}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :plain, "stuck")
        Ash.Seed.update!(blob, %{service_name: AshStorage.Test.FailingDeleteService})

        log = capture_log(fn -> assert {:ok, [_]} = Operations.purge(post, :plain, m.caller) end)

        assert log =~ blob.key
        assert attachments(m, post, :plain) == []
        assert {:error, _} = Ash.get(m.blob, blob.id, m.inspect)
      end)
    end

    test "P6. a synchronous host destroy removes variants too", %{m: m} do
      KnownGap.check(gaps(m), {:host_destroy, :removes_variants}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :doc, "shout")
        [variant] = Ash.load!(blob, :variants, m.inspect).variants

        Ash.destroy!(post, m.caller)

        assert {:error, _} = Ash.get(m.blob, blob.id, m.inspect)
        assert {:error, _} = Ash.get(m.blob, variant.id, m.inspect)
        refute Store.exists?(blob.key)
        refute Store.exists?(variant.key)
      end)
    end

    test "P8. a host destroy keeps a blob another record uses", %{m: m} do
      KnownGap.check(gaps(m), {:host_destroy, :keeps_shared_blob}, fn ->
        post = post!(m)
        other = post!(m)
        {:ok, %{blob: shared}} = attach(m, :action, post, :plain, "shared")
        {:ok, _} = attach_blob(m, other, :plain, shared)

        Ash.destroy!(post, m.caller)

        assert {:ok, _} = Ash.get(m.blob, shared.id, m.inspect)
        assert Store.exists?(shared.key)
      end)
    end

    test "P9. detach_<name> keeps the blob and the file", %{m: m} do
      KnownGap.check(gaps(m), {:detach, :keeps_blob}, fn ->
        post = post!(m)
        {:ok, %{blob: blob}} = attach(m, :action, post, :plain, "kept")

        assert {:ok, [_]} = Operations.detach(post, :plain, m.caller)

        assert attachments(m, post, :plain) == []
        assert {:ok, _} = Ash.get(m.blob, blob.id, m.inspect)
        assert Store.exists?(blob.key)
      end)
    end
  end

  # -- Helpers --

  defp gaps(m), do: Map.merge(@gaps, m.gaps)

  defp slug, do: "post-#{System.unique_integer([:positive])}"

  defp post!(m), do: Ash.create!(m.post, %{slug: slug()}, m.caller)

  # Attaches `content` to `record` through `entry`, as the configuration's
  # caller, and returns the record with the blob and attachment the entry point
  # reported.
  defp attach(m, entry, record, name, content, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "text/plain")
    filename = "#{name}.txt"

    case entry do
      :action ->
        Operations.attach(
          record,
          name,
          content,
          [filename: filename, content_type: content_type] ++ m.caller
        )

      :file_argument ->
        record
        |> Ash.Changeset.for_update(
          :"update_#{name}",
          %{name => upload(name, content, content_type)},
          m.caller
        )
        |> Ash.update()
        |> entry_result(name)

      :direct_upload ->
        blob = direct_upload!(m, name, content, content_type)

        record
        |> Ash.Changeset.for_update(
          :"update_#{name}_blob",
          %{:"#{name}_blob_id" => blob.id},
          m.caller
        )
        |> Ash.update()
        |> entry_result(name)
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

  defp entry_result({:ok, record}, name) do
    {:ok,
     %{
       record: record,
       blob: record.__metadata__[:"#{name}_blob"],
       attachment: record.__metadata__[:"#{name}_attachment"]
     }}
  end

  defp entry_result({:error, _} = error, _name), do: error

  defp direct_upload!(m, name, content, content_type \\ "text/plain") do
    {:ok, %{blob: blob}} =
      Operations.prepare_direct_upload(
        m.post,
        name,
        [filename: "#{name}.txt", content_type: content_type, byte_size: byte_size(content)] ++
          m.caller
      )

    :ok = Store.upload(blob.key, content, AshStorage.Service.Context.new([]))
    blob
  end

  defp upload(name, content, content_type \\ "text/plain") do
    path = Path.join(Process.get(:matrix_tmp_dir), "#{System.unique_integer([:positive])}")
    File.write!(path, content)
    %Plug.Upload{path: path, filename: "#{name}.txt", content_type: content_type}
  end

  # Creates a record with its first file in `:doc`. The generated action needs
  # a record, so `:action` creates one and attaches to it.
  defp create_with(m, :action, content) do
    attach(m, :action, post!(m), :doc, content)
  end

  defp create_with(m, :file_argument, content) do
    m.post
    |> Ash.Changeset.for_create(
      :create_with_doc,
      %{slug: slug(), doc: upload(:doc, content)},
      m.caller
    )
    |> Ash.create()
    |> entry_result(:doc)
  end

  defp create_with(m, :direct_upload, content) do
    blob = direct_upload!(m, :doc, content)

    m.post
    |> Ash.Changeset.for_create(
      :create_with_doc_blob,
      %{slug: slug(), doc_blob_id: blob.id},
      m.caller
    )
    |> Ash.create()
    |> entry_result(:doc)
  end

  # Reads the rows directly: loading a has_one relationship hides duplicates.
  defp attachments(m, post, name) do
    relationship = Ash.Resource.Info.relationship(post.__struct__, name)

    relationship.destination
    |> Ash.Query.filter(
      ^[{:name, to_string(name)}, {relationship.destination_attribute, post.id}]
    )
    |> Ash.read!(m.inspect)
  end
end

defmodule AshStorage.AttachMatrixActorTest do
  # The policy configuration of the attach matrix, called with
  # `authorize?: false` and no actor instead: the library's calls carry the
  # caller's `authorize?`, so the policies are skipped there too.
  use ExUnit.Case, async: false

  require Ash.Query

  alias AshStorage.Operations
  alias AshStorage.Service.Test, as: Store
  alias AshStorage.Test.MatrixConfig

  @caller [authorize?: false]

  setup do
    Store.reset!()
    %{m: MatrixConfig.build(:actor)}
  end

  for entry <- [:action, :file_argument, :direct_upload] do
    test "an update replaces the file through #{entry}", %{m: m} do
      post = Ash.create!(m.post, %{slug: "unauthorized"}, @caller)

      {:ok, old} = attach(unquote(entry), m, post, "old")
      {:ok, new} = attach(unquote(entry), m, post, "new")

      assert [%{blob_id: blob_id}] =
               m.attachment
               |> Ash.Query.filter(name == "plain" and post_id == ^post.id)
               |> Ash.read!(m.inspect)

      assert blob_id == new.id
      assert {:error, _} = Ash.get(m.blob, old.id, m.inspect)
      refute Store.exists?(old.key)
    end
  end

  defp attach(:action, _m, post, content) do
    with {:ok, %{blob: blob}} <-
           Operations.attach(post, :plain, content, [filename: "plain.txt"] ++ @caller),
         do: {:ok, blob}
  end

  defp attach(:file_argument, _m, post, content) do
    path = tmp_path()
    File.write!(path, content)
    upload = %Plug.Upload{path: path, filename: "plain.txt", content_type: "text/plain"}

    try do
      with {:ok, post} <-
             post
             |> Ash.Changeset.for_update(:update_plain, %{plain: upload}, @caller)
             |> Ash.update(),
           do: {:ok, post.__metadata__[:plain_blob]}
    after
      File.rm(path)
    end
  end

  defp attach(:direct_upload, m, post, content) do
    {:ok, %{blob: blob}} =
      Operations.prepare_direct_upload(m.post, :plain, [filename: "plain.txt"] ++ @caller)

    :ok = Store.upload(blob.key, content, AshStorage.Service.Context.new([]))

    with {:ok, post} <-
           post
           |> Ash.Changeset.for_update(:update_plain_blob, %{plain_blob_id: blob.id}, @caller)
           |> Ash.update(),
         do: {:ok, post.__metadata__[:plain_blob]}
  end

  defp tmp_path,
    do: Path.join(System.tmp_dir!(), "ash_storage_matrix_actor_#{System.unique_integer()}")
end
