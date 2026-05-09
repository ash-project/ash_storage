defmodule AshStorage.BlobResource.Changes.RunPendingVariants do
  @moduledoc """
  A change that fans out one Oban job per still-pending variant on the blob,
  delegating the actual work to the per-variant `:run_pending_variant` action.

  Used by the `:run_pending_variants` action. Typically invoked from the
  AshOban scheduler (cron-driven recovery) for blobs whose `pending_variants`
  flag is still `true` — for example because an `:run_pending_variant` enqueue
  was lost. Iterates `metadata["__pending_variants__"]`, finds entries with
  `"status" => "pending"`, and re-enqueues each via
  `AshOban.run_trigger(blob, :run_pending_variant, action_arguments: %{...})`.

  This change does **not** generate variants itself; it only schedules jobs.
  Calling `Ash.update(blob, %{}, action: :run_pending_variants)` synchronously
  produces `{:ok, blob}` with the same data, but per-variant jobs land in
  Oban for asynchronous execution.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, blob ->
      blob.metadata
      |> Map.get("__pending_variants__", %{})
      |> Enum.filter(fn {_name, info} -> info["status"] == "pending" end)
      |> Enum.each(fn {variant_name, _info} ->
        opts = [action_arguments: %{variant_name: variant_name}]
        AshOban.run_trigger(blob, :run_pending_variant, opts)
      end)

      {:ok, blob}
    end)
  end
end
