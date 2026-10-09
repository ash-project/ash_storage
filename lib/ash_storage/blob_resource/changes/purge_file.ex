defmodule AshStorage.BlobResource.Changes.PurgeFile do
  @moduledoc """
  A change that deletes the file from storage when a blob is destroyed.

  This is used by the `:purge_blob` action on blob resources. It loads
  the `parsed_service_opts` calculation to reconstitute the service options
  from the stored map, then deletes the file before the record is destroyed.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      blob = changeset.data |> Ash.load!(:parsed_service_opts)
      service_mod = blob.service_name
      service_opts = blob.parsed_service_opts || []

      ctx = AshStorage.Service.Context.new(service_opts)

      case service_mod.delete(blob.key, ctx) do
        :ok ->
          changeset

        {:error, reason} ->
          Ash.Changeset.add_error(
            changeset,
            "Failed to delete file from storage: #{inspect(reason)}"
          )
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "deleting the file from storage requires the record being destroyed"}
  end
end
