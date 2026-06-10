defmodule AshStorage.Changes.Purge do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Service.Context

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
           {:ok, to_purge} <- select_for_purge(attachments, attachment_def, blob_id, all?),
           {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def) do
        ctx = build_context(service_opts, resource, attachment_def, changeset)

        case purge_attachments(to_purge, service_mod, ctx, context_opts) do
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

  defp resolve_service(resource, attachment_def) do
    case Info.service_for_attachment(resource, attachment_def) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :no_service_configured}
    end
  end

  defp build_context(service_opts, resource, attachment_def, changeset) do
    Context.new(service_opts,
      resource: resource,
      attachment: attachment_def,
      actor: changeset.context[:private][:actor],
      tenant: changeset.tenant
    )
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

  defp purge_attachments(attachments, service_mod, ctx, context_opts) do
    destroy_opts = Keyword.merge(context_opts, action: :destroy, return_destroyed?: true)

    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
      blob = att.blob

      with :ok <- service_mod.delete(blob.key, ctx),
           {:ok, _} <- Ash.destroy(att, destroy_opts),
           {:ok, _} <- Ash.destroy(blob, destroy_opts) do
        {:cont, {:ok, [att | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
