defmodule AshStorage.Changes.Purge do
  @moduledoc false
  use Ash.Resource.Change

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Hooks, Scope}

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, context) do
    attachment_name = opts[:attachment_name]
    nested? = Hooks.nested?(changeset)

    changeset
    |> Ash.Changeset.after_action(fn changeset, record ->
      scope = Scope.from_change(changeset, context)
      blob_id = Ash.Changeset.get_argument(changeset, :blob_id)
      all? = Ash.Changeset.get_argument(changeset, :all) || false

      with {:ok, target} <- Pipeline.resolve(record.__struct__, attachment_name),
           {:ok, attachments} <- Pipeline.attachments(record, target, scope),
           {:ok, to_purge} <- Pipeline.select(attachments, target, blob_id, all?),
           {:ok, %{attachments: purged, deletions: deletions}} <-
             Pipeline.unlink(to_purge, :purge, target, scope) do
        {:ok,
         record
         |> Ash.Resource.put_metadata(:purged_attachments, purged)
         |> Hooks.defer_deletions(deletions, nested?)}
      end
    end)
    |> Hooks.delete_after_transaction(nested?)
  end
end
