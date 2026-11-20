defmodule AshStorage.Changes.Purge do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Scope, Target}

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, context) do
    attachment_name = opts[:attachment_name]

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      scope = Scope.from_change(changeset, context)
      blob_id = Ash.Changeset.get_argument(changeset, :blob_id)
      all? = Ash.Changeset.get_argument(changeset, :all) || false

      with {:ok, target} <- Pipeline.resolve(record.__struct__, attachment_name),
           {:ok, attachments} <- find_attachments(record, target.attachment, scope),
           {:ok, to_purge} <- select_for_purge(attachments, target.attachment, blob_id, all?),
           {:ok, {service_mod, ctx}} <- Target.service_context(target, scope) do
        case purge_attachments(to_purge, service_mod, ctx, scope) do
          {:ok, purged} ->
            {:ok, Ash.Resource.put_metadata(record, :purged_attachments, purged)}

          {:error, error} ->
            {:error, error}
        end
      end
    end)
  end

  defp select_for_purge(attachments, %{type: :one}, _blob_id, _all?), do: {:ok, attachments}

  defp select_for_purge(attachments, %{type: :many}, _blob_id, true), do: {:ok, attachments}

  defp select_for_purge(attachments, %{type: :many}, blob_id, _all?) when not is_nil(blob_id) do
    {:ok, Enum.filter(attachments, &(&1.blob_id == blob_id))}
  end

  defp select_for_purge(_attachments, %{type: :many}, nil, false) do
    {:error, :blob_id_required_for_has_many}
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp find_attachments(record, attachment_def, scope) do
    resource = record.__struct__
    attachment_resource = Info.storage_attachment_resource!(resource)
    record_id = Map.get(record, :id) |> to_string()

    belongs_to_resources =
      Spark.Dsl.Extension.get_entities(attachment_resource, [:attachment])

    parent_rel =
      Enum.find(belongs_to_resources, fn bt ->
        bt.resource == resource
      end)

    filter =
      if parent_rel do
        [{:name, to_string(attachment_def.name)}, {:"#{parent_rel.name}_id", record_id}]
      else
        [
          name: to_string(attachment_def.name),
          record_type: to_string(resource),
          record_id: record_id
        ]
      end

    attachment_resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.load(:blob)
    |> Ash.read(Scope.to_opts(scope))
  end

  defp purge_attachments(attachments, service_mod, ctx, scope) do
    destroy_opts = Scope.to_opts(scope, action: :destroy, return_destroyed?: true)

    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
      blob = att.blob

      with {:ok, _} <- Ash.destroy(att, destroy_opts),
           {:ok, _} <- Ash.destroy(blob, destroy_opts),
           :ok <- AshStorage.Operations.delete_blob_file(blob, service_mod, ctx) do
        {:cont, {:ok, [att | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
