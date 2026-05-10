defmodule AshStorage.VariantSchedulerTest do
  @moduledoc """
  Tests for `AshStorage.VariantScheduler` — the module that decides *which*
  units (variants and groups) get enqueued and *when*, based on per-variant
  `group:` and `order:` declarations. Per-action lifecycle behavior lives in
  `AshStorage.VariantObanTest`; this file focuses on tier advancement,
  cross-tier dispatch, and recovery semantics.
  """
  use AshStorage.RepoCase, async: false
  use Oban.Testing, repo: AshStorage.TestRepo

  @moduletag :oban

  alias AshStorage.Test.{PgBlob, PgPost}

  @variant_worker AshStorage.Test.PgBlob.RunPendingVariantWorker
  @variants_worker AshStorage.Test.PgBlob.RunPendingVariantsWorker

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

  defp complete_all_at_order!(blob, order) do
    blob = Ash.get!(PgBlob, blob.id)

    blob.metadata["__pending_variants__"]
    |> Enum.filter(fn {_n, info} -> info["status"] == "pending" and info["order"] == order end)
    |> Enum.reduce(blob, fn {name, _info}, blob ->
      Ash.update!(blob, %{variant_name: name, status: "complete"}, action: :complete_variant)
    end)
  end

  describe "schedule_next (tier advancement on completion)" do
    test "completing all order=0 units enqueues the order=1 unit" do
      post = create_post!()
      blob = attach!(post)

      AshStorage.TestRepo.delete_all(Oban.Job)

      blob = complete_all_at_order!(blob, 0)

      pending = blob.metadata["__pending_variants__"]

      assert [] =
               Enum.filter(pending, fn {_, i} ->
                 i["status"] == "pending" and i["order"] == 0
               end)

      # Advance via the recovery action — same dispatch path as the worker hook.
      {:ok, _} = Ash.update(blob, %{}, action: :schedule_pending_variants)

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )
    end

    test "running the last order=0 unit through the worker path enqueues order=1" do
      post = create_post!()
      blob = attach!(post)

      # Run every order=0 unit through the dispatcher so its tail
      # (VariantScheduler.schedule_next/2) fires.
      {:ok, _} = Ash.update(blob, %{variant_name: "oban_upper"}, action: :run_pending_variants)
      {:ok, _} = Ash.update(blob, %{variant_name: "oban_reverse"}, action: :run_pending_variants)
      {:ok, _} = Ash.update(blob, %{group: "fast"}, action: :run_pending_variants)

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )

      blob = Ash.get!(PgBlob, blob.id)
      assert blob.metadata["__pending_variants__"]["oban_later"]["status"] == "pending"
    end

    test "running only some order=0 units does NOT enqueue order=1" do
      post = create_post!()
      blob = attach!(post)
      AshStorage.TestRepo.delete_all(Oban.Job)

      {:ok, _} = Ash.update(blob, %{variant_name: "oban_upper"}, action: :run_pending_variants)

      refute_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )
    end
  end

  describe "recover (:schedule_pending_variants cron)" do
    test "advances to the next pending tier once the lowest empties" do
      post = create_post!()
      blob = attach!(post)

      _ = complete_all_at_order!(blob, 0)
      AshStorage.TestRepo.delete_all(Oban.Job)

      blob = Ash.get!(PgBlob, blob.id)
      {:ok, _} = Ash.update(blob, %{}, action: :schedule_pending_variants)

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )
    end
  end

  describe "multi-tier dispatch with groups + solos at multiple orders" do
    # Resource recap:
    #   order=0: solos `oban_upper`, `oban_reverse` + group `:fast` → 3 units
    #   order=1: solos `oban_later`, `oban_extra_late` + group `:slow` → 3 units
    #
    # Asserts the scheduler:
    #   - dispatches only the lowest-order tier at attach (no peek-ahead),
    #   - waits for every unit in that tier (groups AND solos) to drain,
    #   - then fans out the entire next tier in one go.

    test "attach enqueues the order=0 tier (3 units) but not the order=1 tier (3 units)" do
      post = create_post!()
      _blob = attach!(post)

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_upper"}}
      )

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_reverse"}}
      )

      assert_enqueued(
        worker: @variants_worker,
        args: %{"action_arguments" => %{"group" => "fast"}}
      )

      refute_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )

      refute_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_extra_late"}}
      )

      refute_enqueued(
        worker: @variants_worker,
        args: %{"action_arguments" => %{"group" => "slow"}}
      )
    end

    test "draining order=0 through the worker path fans out the entire order=1 tier" do
      post = create_post!()
      blob = attach!(post)

      # Drain attach-time enqueues so we only inspect what the worker hook adds.
      AshStorage.TestRepo.delete_all(Oban.Job)

      # Run every order=0 unit through the worker. Each call triggers
      # VariantScheduler.schedule_next/2; only the LAST one finds the tier
      # empty and dispatches order=1.
      {:ok, _} = Ash.update(blob, %{variant_name: "oban_upper"}, action: :run_pending_variant)
      {:ok, _} = Ash.update(blob, %{variant_name: "oban_reverse"}, action: :run_pending_variant)
      {:ok, _} = Ash.update(blob, %{group: "fast"}, action: :run_pending_variants)

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_extra_late"}}
      )

      assert_enqueued(
        worker: @variants_worker,
        args: %{"action_arguments" => %{"group" => "slow"}}
      )
    end

    test "intermediate completions inside order=0 do NOT prematurely fan out order=1" do
      post = create_post!()
      blob = attach!(post)

      AshStorage.TestRepo.delete_all(Oban.Job)

      # Complete two of the three order=0 units; the :fast group remains pending.
      {:ok, _} = Ash.update(blob, %{variant_name: "oban_upper"}, action: :run_pending_variant)
      {:ok, _} = Ash.update(blob, %{variant_name: "oban_reverse"}, action: :run_pending_variant)

      refute_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )

      refute_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_extra_late"}}
      )

      refute_enqueued(
        worker: @variants_worker,
        args: %{"action_arguments" => %{"group" => "slow"}}
      )

      # Finish the last order=0 unit — order=1 fans out now.
      {:ok, _} = Ash.update(blob, %{group: "fast"}, action: :run_pending_variants)

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_later"}}
      )

      assert_enqueued(
        worker: @variant_worker,
        args: %{"action_arguments" => %{"variant_name" => "oban_extra_late"}}
      )

      assert_enqueued(
        worker: @variants_worker,
        args: %{"action_arguments" => %{"group" => "slow"}}
      )
    end
  end
end
