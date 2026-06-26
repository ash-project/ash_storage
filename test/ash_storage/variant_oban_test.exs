defmodule AshStorage.VariantObanTest do
  use AshStorage.RepoCase, async: false
  use Oban.Testing, repo: AshStorage.TestRepo

  @moduletag :oban

  alias AshStorage.Test.{PgBlob, PgPost}

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test post") do
    PgPost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  defp attach!(post, content \\ "hello world") do
    {:ok, %{blob: blob}} =
      AshStorage.Operations.attach(post, :cover_image, content,
        filename: "test.txt",
        content_type: "text/plain"
      )

    blob
  end

  describe "eager variant generation on Postgres" do
    test "generates eager variant blobs during attach" do
      post = create_post!()
      blob = attach!(post)

      blob = Ash.load!(blob, :variants)

      eager = Enum.find(blob.variants, &(&1.variant_name == "eager_upper"))
      assert eager != nil
      assert eager.variant_of_blob_id == blob.id

      {:ok, data} = AshStorage.Service.Test.download(eager.key, [])
      assert data == "HELLO WORLD"
    end
  end

  describe "oban variant generation on Postgres" do
    test "stores pending variant info in blob metadata" do
      post = create_post!()
      blob = attach!(post)

      pending = blob.metadata["__pending_variants__"]
      assert pending != nil
      assert pending["oban_upper"]["status"] == "pending"
      assert pending["oban_upper"]["module"] == to_string(AshStorage.Test.UppercaseVariant)
      assert pending["oban_reverse"]["status"] == "pending"
      assert pending["oban_reverse"]["module"] == to_string(AshStorage.Test.ReverseVariant)

      # Group + order metadata is persisted alongside module/opts so the worker
      # and scheduler can rehydrate units without walking the DSL at runtime.
      assert pending["oban_upper"]["group"] == nil
      assert pending["oban_upper"]["order"] == 0
      assert pending["oban_grouped_a"]["group"] == "fast"
      assert pending["oban_grouped_a"]["order"] == 0
      assert pending["oban_grouped_b"]["group"] == "fast"
      assert pending["oban_later"]["group"] == nil
      assert pending["oban_later"]["order"] == 1
    end

    test "pending_variants flag is set during attach" do
      post = create_post!()
      blob = attach!(post)

      assert blob.pending_variants == true
    end

    test "attach enqueues one Oban job per oban variant" do
      post = create_post!()
      blob = attach!(post)

      # Solo variants land on the singular per-variant worker.
      assert_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantWorker,
        args: %{
          "action_arguments" => %{"variant_name" => "oban_upper"},
          "primary_key" => %{"id" => blob.id}
        }
      )

      assert_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantWorker,
        args: %{
          "action_arguments" => %{"variant_name" => "oban_reverse"},
          "primary_key" => %{"id" => blob.id}
        }
      )

      # Grouped variants share one job on the multi-unit dispatcher worker.
      assert_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantsWorker,
        args: %{
          "action_arguments" => %{"group" => "fast"},
          "primary_key" => %{"id" => blob.id}
        }
      )

      # Higher-order tiers wait — order=1 units don't show up at attach.
      refute_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantWorker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )

      # The cron recovery worker also doesn't get scheduled by attach.
      refute_enqueued(worker: AshStorage.Test.PgBlob.SchedulePendingVariantsWorker)
    end

    test "run_pending_variant action generates a single variant blob and marks it complete" do
      post = create_post!()
      blob = attach!(post)

      {:ok, blob} =
        Ash.update(blob, %{variant_name: "oban_upper"}, action: :run_pending_variant)

      blob = Ash.load!(blob, :variants)
      upper = Enum.find(blob.variants, &(&1.variant_name == "oban_upper"))
      assert upper != nil
      {:ok, data} = AshStorage.Service.Test.download(upper.key, [])
      assert data == "HELLO WORLD"

      # The reverse variant should not have been touched.
      assert Enum.find(blob.variants, &(&1.variant_name == "oban_reverse")) == nil

      blob = Ash.get!(PgBlob, blob.id)
      pending = blob.metadata["__pending_variants__"]
      assert pending["oban_upper"]["status"] == "complete"
      assert pending["oban_reverse"]["status"] == "pending"
      assert blob.pending_variants == true
    end

    test "running all variants clears the pending_variants flag" do
      post = create_post!()
      blob = attach!(post)

      names = [
        "oban_upper",
        "oban_reverse",
        "oban_grouped_a",
        "oban_grouped_b",
        "oban_later",
        "oban_extra_late",
        "oban_slow_x",
        "oban_slow_y"
      ]

      Enum.each(names, fn name ->
        blob = Ash.get!(PgBlob, blob.id)
        {:ok, _} = Ash.update(blob, %{variant_name: name}, action: :run_pending_variant)
      end)

      blob = Ash.get!(PgBlob, blob.id)
      assert blob.pending_variants == false

      pending = blob.metadata["__pending_variants__"]
      assert pending["oban_upper"]["status"] == "complete"
      assert pending["oban_reverse"]["status"] == "complete"
    end

    test "run_pending_variant is a no-op when the variant is already complete" do
      post = create_post!()
      blob = attach!(post)

      {:ok, _} = Ash.update(blob, %{variant_name: "oban_upper"}, action: :run_pending_variant)
      blob = Ash.get!(PgBlob, blob.id)

      # Re-running the same variant should not error and should not re-create the variant blob.
      {:ok, _} = Ash.update(blob, %{variant_name: "oban_upper"}, action: :run_pending_variant)

      blob = Ash.load!(Ash.get!(PgBlob, blob.id), :variants)

      uppers = Enum.filter(blob.variants, &(&1.variant_name == "oban_upper"))
      assert length(uppers) == 1
    end

    test "run_pending_variant is a no-op when the variant entry is missing" do
      post = create_post!()
      blob = attach!(post)

      {:ok, _} =
        Ash.update(blob, %{variant_name: "does_not_exist"}, action: :run_pending_variant)

      blob = Ash.get!(PgBlob, blob.id)
      pending = blob.metadata["__pending_variants__"]
      assert pending["oban_upper"]["status"] == "pending"
      assert blob.pending_variants == true
    end
  end

  describe "run_pending_variants fan-out" do
    test "enqueues one Oban job per still-pending variant" do
      post = create_post!()
      blob = attach!(post)

      Oban.Testing.with_testing_mode(:manual, fn ->
        :ok = drop_all_oban_jobs!()
      end)

      {:ok, _} = Ash.update(blob, %{}, action: :schedule_pending_variants)

      # Solo order=0 variants enqueue on the singular worker.
      assert_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantWorker,
        args: %{"action_arguments" => %{"variant_name" => "oban_upper"}}
      )

      assert_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantWorker,
        args: %{"action_arguments" => %{"variant_name" => "oban_reverse"}}
      )

      # The order=0 group enqueues on the multi-unit dispatcher.
      assert_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantsWorker,
        args: %{"action_arguments" => %{"group" => "fast"}}
      )

      # Higher-order tiers stay queued behind order=0.
      refute_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantWorker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )
    end

    test "skips entries already marked non-pending" do
      post = create_post!()
      blob = attach!(post)

      # Run one variant inline so its status flips to "complete".
      {:ok, _} = Ash.update(blob, %{variant_name: "oban_upper"}, action: :run_pending_variant)

      :ok = drop_all_oban_jobs!()

      blob = Ash.get!(PgBlob, blob.id)
      {:ok, _} = Ash.update(blob, %{}, action: :schedule_pending_variants)

      refute_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantWorker,
        args: %{"action_arguments" => %{"variant_name" => "oban_upper"}}
      )

      assert_enqueued(
        worker: AshStorage.Test.PgBlob.RunPendingVariantWorker,
        args: %{"action_arguments" => %{"variant_name" => "oban_reverse"}}
      )
    end
  end

  describe "complete_variant atomic update" do
    test "updates one variant's status without disturbing siblings" do
      post = create_post!()
      blob = attach!(post)

      {:ok, blob} =
        Ash.update(blob, %{variant_name: "oban_upper", status: "complete"},
          action: :complete_variant
        )

      pending = blob.metadata["__pending_variants__"]
      assert pending["oban_upper"]["status"] == "complete"
      assert pending["oban_reverse"]["status"] == "pending"
      assert blob.pending_variants == true

      {:ok, blob} =
        Ash.update(blob, %{variant_name: "oban_reverse", status: "complete"},
          action: :complete_variant
        )

      pending = blob.metadata["__pending_variants__"]
      assert pending["oban_upper"]["status"] == "complete"
      assert pending["oban_reverse"]["status"] == "complete"
      # The other oban variants are still pending so the flag stays true.
      assert blob.pending_variants == true
    end
  end

  defp drop_all_oban_jobs! do
    AshStorage.TestRepo.delete_all(Oban.Job)
    :ok
  end
end
