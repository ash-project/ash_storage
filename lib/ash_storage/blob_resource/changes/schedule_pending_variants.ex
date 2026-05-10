defmodule AshStorage.BlobResource.Changes.SchedulePendingVariants do
  @moduledoc """
  Cron-driven recovery: re-fans-out the lowest still-pending variant tier on
  blobs whose `pending_variants == true`.

  Used by the `:schedule_pending_variants` action. Delegates to
  `AshStorage.VariantScheduler.recover/1`, which is idempotent — duplicate
  enqueues are absorbed by the worker's "this entry is no longer pending"
  short-circuit.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, blob ->
      AshStorage.VariantScheduler.recover(blob)
      {:ok, blob}
    end)
  end
end
