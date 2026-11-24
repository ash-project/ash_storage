defmodule AshStorage.BlobResource.Changes.PurgeFile do
  @moduledoc """
  A change that deletes the file from storage when a blob is destroyed.

  This is used by the `:purge_blob` action on blob resources. Before the blob
  is destroyed it destroys the blob's variants, whose rows reference it. Once
  the rows are gone it deletes the variants' files and then the blob's own,
  each with the service options stored on its row.

  The files are deleted inside the action's transaction, so if a row can't be
  destroyed every file is kept, and if a file can't be deleted the destroy is
  rolled back. Services treat deleting a missing file as success, so a purge
  that fails after some files are gone can be retried.
  """
  use Ash.Resource.Change

  alias AshStorage.Pipeline.{Purge, Scope, Target}

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      blob = changeset.data
      scope = Scope.from_change(changeset, context)

      case Purge.destroy_variants(blob, scope) do
        {:ok, deletions} ->
          deletions =
            deletions ++ [{blob.service_name, Target.blob_context(blob, scope), blob.key}]

          Ash.Changeset.put_context(changeset, :__ash_storage_purge__, deletions)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      changeset.context.__ash_storage_purge__
      |> Enum.reduce_while({:ok, record}, fn {service_mod, ctx, key}, result ->
        case service_mod.delete(key, ctx) do
          :ok ->
            {:cont, result}

          {:error, reason} ->
            {:halt, {:error, "Failed to delete file from storage: #{inspect(reason)}"}}
        end
      end)
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "deleting the file from storage requires the record being destroyed"}
  end
end
