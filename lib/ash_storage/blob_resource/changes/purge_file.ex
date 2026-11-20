defmodule AshStorage.BlobResource.Changes.PurgeFile do
  @moduledoc """
  A change that deletes the file from storage when a blob is destroyed.

  This is used by the `:purge_blob` action on blob resources. It reconstitutes
  the service options from the map stored on the blob, then deletes the file
  once the record has been destroyed.

  The file is deleted inside the action's transaction, so if the record can't
  be destroyed the file is kept, and if the file can't be deleted the destroy
  is rolled back. Services treat deleting a missing file as success, so a purge
  that fails after the file is gone can be retried.
  """
  use Ash.Resource.Change

  alias AshStorage.Pipeline.{Scope, Target}

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      # Built before the record is destroyed, while it can still be read
      blob = changeset.data
      ctx = Target.blob_context(blob, Scope.from_change(changeset, context))

      Ash.Changeset.put_context(changeset, :__ash_storage_purge__, {blob.service_name, ctx})
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      {service_mod, ctx} = changeset.context.__ash_storage_purge__

      case service_mod.delete(changeset.data.key, ctx) do
        :ok ->
          {:ok, record}

        {:error, reason} ->
          {:error, "Failed to delete file from storage: #{inspect(reason)}"}
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "deleting the file from storage requires the record being destroyed"}
  end
end
