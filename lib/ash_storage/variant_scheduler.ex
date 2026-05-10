defmodule AshStorage.VariantScheduler do
  @moduledoc """
  Decides which oban variant jobs to enqueue and when, based on the per-variant
  `group:` and `order:` declarations on the attachment.

  Three entry points:

  - `schedule_initial/2` — called at attach time with the attachment_def in
    hand. Enqueues every unit (variant or group) at the lowest declared
    `order` tier; later tiers wait.
  - `schedule_next/2` — called after a variant or group completes. If the
    completed unit's tier is now empty, fans out the next non-empty tier;
    otherwise no-op.
  - `recover/1` — called by the cron-driven `:schedule_pending_variants`
    action. Re-fans-out the lowest still-pending tier, tolerating "an
    enqueue was lost earlier" without knowing which.

  A "unit" is either a single variant (no `group:`) or a named group
  (`group: :name`, where every variant sharing that group runs serially in
  one Oban job).
  """

  @pending_key "__pending_variants__"

  @doc "Enqueue the lowest-`order` tier from the DSL at attach time."
  def schedule_initial(blob, attachment_def) do
    (attachment_def.variants || [])
    |> oban_units_from_dsl()
    |> dispatch_lowest_tier(blob)
  end

  @doc """
  After a unit at `completed_order` finishes, advance the tier if no other
  units at that order remain pending.
  """
  def schedule_next(blob, completed_order) when is_integer(completed_order) do
    pending = pending_entries(blob)

    if Enum.any?(pending, fn {_name, info} -> info["order"] == completed_order end) do
      :ok
    else
      pending
      |> Enum.filter(fn {_name, info} -> info["order"] > completed_order end)
      |> oban_units_from_metadata()
      |> dispatch_lowest_tier(blob)
    end
  end

  @doc "Re-fan-out the lowest still-pending tier (cron recovery)."
  def recover(blob) do
    blob
    |> pending_entries()
    |> oban_units_from_metadata()
    |> dispatch_lowest_tier(blob)
  end

  # ----- internals -----

  defp pending_entries(blob) do
    blob.metadata
    |> Kernel.||(%{})
    |> Map.get(@pending_key, %{})
    |> Enum.filter(fn {_name, info} -> info["status"] == "pending" end)
  end

  defp oban_units_from_dsl(variant_defs) do
    variant_defs
    |> Enum.filter(&(&1.generate == :oban))
    |> Enum.flat_map(fn defn ->
      case defn.group do
        nil -> [{:variant, to_string(defn.name), defn.order || 0}]
        group -> [{:group, to_string(group), defn.order || 0}]
      end
    end)
    |> Enum.uniq()
  end

  defp oban_units_from_metadata(entries) do
    entries
    |> Enum.flat_map(fn {name, info} ->
      order = info["order"] || 0

      case info["group"] do
        nil -> [{:variant, name, order}]
        group -> [{:group, to_string(group), order}]
      end
    end)
    |> Enum.uniq()
  end

  defp dispatch_lowest_tier([], _blob), do: :ok

  defp dispatch_lowest_tier(units, blob) do
    min_order = units |> Enum.map(&elem(&1, 2)) |> Enum.min()

    units
    |> Enum.filter(&(elem(&1, 2) == min_order))
    |> Enum.each(&enqueue(blob, &1))

    :ok
  end

  defp enqueue(blob, {:variant, name, _order}) do
    AshOban.run_trigger(blob, :run_pending_variant, action_arguments: %{variant_name: name})
  end

  defp enqueue(blob, {:group, name, _order}) do
    AshOban.run_trigger(blob, :run_pending_variants, action_arguments: %{group: name})
  end
end
