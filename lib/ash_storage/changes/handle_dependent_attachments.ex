defmodule AshStorage.Changes.HandleDependentAttachments do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    if changeset.action.soft? do
      changeset
    else
      context_opts = Ash.Context.to_opts(context)
      resource = changeset.resource
      async? = async_purge?(resource)

      # Find attachments BEFORE the action runs, because ON DELETE SET NULL
      # will nilify the FK after the SQL DELETE executes, making them unfindable.
      changeset =
        Ash.Changeset.before_action(changeset, fn changeset ->
          record = changeset.data
          attachments_by_name = prefetch_attachments(record, context_opts)
          Ash.Changeset.put_context(changeset, :__ash_storage_attachments__, attachments_by_name)
        end)

      changeset =
        Ash.Changeset.after_action(changeset, fn changeset, record ->
          attachments_by_name = changeset.context[:__ash_storage_attachments__] || %{}
          handle_dependent(record, attachments_by_name, async?)
        end)

      if async? do
        changeset
      else
        Ash.Changeset.after_transaction(changeset, &delete_files/2)
      end
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end

  defp async_purge?(resource) do
    blob_resource = AshStorage.Info.storage_blob_resource!(resource)

    Code.ensure_loaded?(AshOban) &&
      Spark.Dsl.Extension.get_persisted(blob_resource, :extensions)
      |> List.wrap()
      |> Enum.member?(AshOban)
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp prefetch_attachments(record, context_opts) do
    resource = record.__struct__
    attachment_defs = AshStorage.Info.attachments(resource)

    Enum.reduce(attachment_defs, %{}, fn attachment_def, acc ->
      case attachment_def.dependent do
        dep when dep in [:purge, :detach] ->
          attachment_resource = AshStorage.Info.storage_attachment_resource!(resource)
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

          case attachment_resource
               |> Ash.Query.filter(^filter)
               |> Ash.Query.load(:blob)
               |> Ash.read(Keyword.take(context_opts, [:actor, :tenant, :authorize?, :tracer])) do
            {:ok, attachments} -> Map.put(acc, attachment_def.name, attachments)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp handle_dependent(record, attachments_by_name, async?) do
    resource = record.__struct__
    attachment_defs = AshStorage.Info.attachments(resource)

    case process_attachments(attachment_defs, attachments_by_name, async?) do
      {:ok, result} ->
        if async? do
          trigger_purge_jobs(result)
          {:ok, record}
        else
          {:ok, Ash.Resource.put_metadata(record, :__ash_storage_keys_to_purge__, result)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp process_attachments(attachment_defs, attachments_by_name, async?) do
    Enum.reduce_while(attachment_defs, {:ok, []}, fn attachment_def, {:ok, acc} ->
      found_attachments = Map.get(attachments_by_name, attachment_def.name, [])

      case attachment_def.dependent do
        :purge ->
          if async? do
            case mark_for_purge(found_attachments) do
              {:ok, blobs} -> {:cont, {:ok, acc ++ blobs}}
              {:error, error} -> {:halt, {:error, error}}
            end
          else
            case destroy_and_collect_keys(found_attachments) do
              {:ok, purge_keys} -> {:cont, {:ok, acc ++ purge_keys}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end

        :detach ->
          case destroy_attachment_records(found_attachments) do
            {:ok, _} -> {:cont, {:ok, acc}}
            {:error, error} -> {:halt, {:error, error}}
          end

        false ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp mark_for_purge(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
      blob = att.blob

      with {:ok, _} <- Ash.destroy(att, action: :destroy, return_destroyed?: true),
           {:ok, blob} <-
             Ash.update(blob, %{pending_purge: true},
               action: :mark_for_purge,
               return_record?: true
             ) do
        {:cont, {:ok, [blob | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp destroy_and_collect_keys(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, keys_acc} ->
      blob = att.blob
      # Capture service info before destroying the blob
      service_mod = blob.service_name
      loaded_blob = Ash.load!(blob, :parsed_service_opts)
      ctx = AshStorage.Service.Context.new(loaded_blob.parsed_service_opts || [])

      with {:ok, _} <- Ash.destroy(att, action: :destroy, return_destroyed?: true),
           {:ok, _} <- Ash.destroy(blob, action: :destroy, return_destroyed?: true) do
        {:cont, {:ok, [{service_mod, ctx, blob.key} | keys_acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp destroy_attachment_records(attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
      case Ash.destroy(att, action: :destroy, return_destroyed?: true) do
        {:ok, destroyed} -> {:cont, {:ok, [destroyed | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp trigger_purge_jobs(blobs) when is_list(blobs) and blobs != [] do
    AshOban.run_triggers(blobs, :purge_blob)
  end

  defp trigger_purge_jobs(_), do: :ok

  # Outside transaction: delete files from storage (only on success, sync mode only)
  defp delete_files(_changeset, {:ok, record}) do
    keys_to_purge = record.__metadata__[:__ash_storage_keys_to_purge__] || []

    Enum.each(keys_to_purge, fn {service_mod, ctx, key} ->
      AshStorage.Operations.delete_from_service(service_mod, ctx, key)
    end)

    {:ok, record}
  end

  defp delete_files(_changeset, {:error, error}), do: {:error, error}
end
