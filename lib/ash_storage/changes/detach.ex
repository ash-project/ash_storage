defmodule AshStorage.Changes.Detach do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.Info

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, context) do
    attachment_name = opts[:attachment_name]
    context_opts = Ash.Context.to_opts(context)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      resource = record.__struct__
      blob_id = Ash.Changeset.get_argument(changeset, :blob_id)
      all? = Ash.Changeset.get_argument(changeset, :all) || false

      with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
           {:ok, attachments} <- find_attachments(record, attachment_def, context_opts),
           {:ok, to_detach} <- select_for_detach(attachments, attachment_def, blob_id, all?) do
        case destroy_attachment_records(to_detach, context_opts) do
          {:ok, destroyed} ->
            {:ok, Ash.Resource.put_metadata(record, :detached_attachments, destroyed)}

          {:error, error} ->
            {:error, error}
        end
      end
    end)
  end

  defp select_for_detach(attachments, %{type: :one}, _blob_id, _all?), do: {:ok, attachments}

  defp select_for_detach(attachments, %{type: :many}, _blob_id, true), do: {:ok, attachments}

  defp select_for_detach(attachments, %{type: :many}, blob_id, _all?) when not is_nil(blob_id) do
    {:ok, Enum.filter(attachments, &(&1.blob_id == blob_id))}
  end

  defp select_for_detach(_attachments, %{type: :many}, nil, false) do
    {:error, :blob_id_required_for_has_many}
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp find_attachments(record, attachment_def, context_opts) do
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
    |> Ash.read(Keyword.take(context_opts, [:actor, :tenant, :authorize?, :tracer]))
  end

  defp destroy_attachment_records(attachments, context_opts) do
    destroy_opts = Keyword.merge(context_opts, action: :destroy, return_destroyed?: true)

    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
      case Ash.destroy(att, destroy_opts) do
        {:ok, destroyed} -> {:cont, {:ok, [destroyed | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
