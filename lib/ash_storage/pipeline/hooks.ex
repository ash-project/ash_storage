defmodule AshStorage.Pipeline.Hooks do
  @moduledoc false
  # Which step runs in which changeset hook. Files that a removal makes
  # obsolete travel from `after_action` to `after_transaction` on the record's
  # metadata: an `after_action` hook cannot change the changeset, and on
  # failure `after_transaction` receives the changeset from before the
  # transaction.

  alias AshStorage.Pipeline.Purge

  @deletions :__ash_storage_deletions__

  @doc """
  Whether the action runs inside a transaction someone else opened. Then
  `after_transaction` hooks run before that transaction commits anyway, and
  Ash warns about each of them, so an action whose own hooks are the last to
  run can delete files at the end of `after_action` instead. Call it from a
  `change/3` body.
  """
  @spec nested?(Ash.Changeset.t()) :: boolean()
  def nested?(changeset), do: Ash.DataLayer.in_transaction?(changeset.resource)

  @doc "Hands `deletions` to the `after_transaction` hook, or deletes them now when nested."
  @spec defer_deletions(struct(), [Purge.deletion()], boolean()) :: struct()
  def defer_deletions(record, [], _nested?), do: record

  def defer_deletions(record, deletions, true) do
    Purge.delete_files(deletions)
    record
  end

  def defer_deletions(record, deletions, false) do
    metadata = Map.update(record.__metadata__, @deletions, deletions, &(&1 ++ deletions))
    %{record | __metadata__: metadata}
  end

  @doc "Registers the hook that deletes the deferred files once the transaction committed."
  @spec delete_after_transaction(Ash.Changeset.t(), boolean()) :: Ash.Changeset.t()
  def delete_after_transaction(changeset, true), do: changeset

  def delete_after_transaction(changeset, false) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, record} ->
        {deletions, metadata} = Map.pop(record.__metadata__, @deletions, [])
        Purge.delete_files(deletions)
        {:ok, %{record | __metadata__: metadata}}

      _changeset, result ->
        result
    end)
  end
end
