defmodule AshStorage.Changes.HandleFileArgument do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.BlobIO
  alias AshStorage.Changes.AnalyzerRun
  alias AshStorage.Info

  @impl true
  def init(opts), do: {:ok, opts}

  # sobelow_skip ["DOS.BinToAtom", "Traversal.FileModule"]
  @impl true
  def change(changeset, opts, context) do
    argument_name = opts[:argument]
    attachment_name = opts[:attachment]
    context_opts = Ash.Context.to_opts(context)

    file = Ash.Changeset.get_argument(changeset, argument_name)

    if is_nil(file) do
      changeset
    else
      changeset
      |> Ash.Changeset.before_action(fn changeset ->
        resource = changeset.resource
        context_opts = Keyword.put(context_opts, :tenant, changeset.tenant)

        case upload_blob(resource, attachment_name, file, changeset, context_opts) do
          {:ok, attrs_to_write, context} ->
            changeset
            |> Ash.Changeset.force_change_attributes(attrs_to_write)
            |> Ash.Changeset.put_context(
              :"__ash_storage_file_arg_#{argument_name}__",
              context
            )

          {:error, error} ->
            Ash.Changeset.add_error(changeset, error)
        end
      end)
      |> Ash.Changeset.after_action(fn changeset, record ->
        context_key = :"__ash_storage_file_arg_#{argument_name}__"

        case changeset.context[context_key] do
          %{blob: blob, attachment_def: attachment_def} = file_context ->
            context_opts = Keyword.put(context_opts, :tenant, changeset.tenant)

            # On update, replace existing attachment; on create, skip
            with {:ok, _} <-
                   maybe_replace_on_update(
                     changeset,
                     record,
                     attachment_def,
                     file_context,
                     context_opts
                   ),
                 {:ok, attachment} <-
                   create_attachment(record, attachment_def, blob, context_opts) do
              # Now that we have the record ID, update write_target for oban analyzers
              if file_context[:has_oban_analyzers?] do
                update_oban_write_targets(blob, record, context_opts)
                AshOban.run_trigger(blob, :run_pending_analyzers, tenant: changeset.tenant)
              end

              record =
                record
                |> Ash.Resource.put_metadata(:"#{attachment_name}_blob", blob)
                |> Ash.Resource.put_metadata(:"#{attachment_name}_attachment", attachment)

              {:ok, record}
            end

          _ ->
            {:ok, record}
        end
      end)
    end
  end

  defp maybe_replace_on_update(
         %{action_type: :create},
         _record,
         _attachment_def,
         _file_context,
         _context_opts
       ) do
    {:ok, :noop}
  end

  defp maybe_replace_on_update(_changeset, record, attachment_def, file_context, context_opts) do
    maybe_replace_existing(
      record,
      attachment_def,
      file_context[:service_mod],
      file_context[:ctx],
      context_opts
    )
  end

  defp upload_blob(resource, attachment_name, file, changeset, context_opts) do
    {filename, content_type} = extract_file_metadata(file)

    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
         {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def) do
      bctx =
        BlobIO.BlobContext.from_changeset(changeset, attachment_def,
          operation: :attach,
          record: changeset.data
        )

      service_ctx = BlobIO.BlobContext.to_service_context(bctx, service_opts)
      key = AshStorage.resolve_key(attachment_def, service_ctx, changeset)

      with {:ok, blob} <-
             upload_and_create_blob(bctx, service_mod, service_opts, file,
               key: key,
               filename: filename,
               content_type: content_type
             ),
           {:ok, blob, attrs_to_write} <-
             AnalyzerRun.run_analyzers(blob, attachment_def, changeset.data, file, context_opts) do
        {:ok, attrs_to_write,
         %{
           blob: blob,
           attachment_def: attachment_def,
           service_mod: service_mod,
           ctx: service_ctx,
           has_oban_analyzers?: AnalyzerRun.has_oban_analyzers?(attachment_def)
         }}
      end
    end
  end

  # After create, we have the real record ID — update write_target in blob's analyzers map
  defp update_oban_write_targets(blob, record, context_opts) do
    analyzers = blob.analyzers || %{}

    has_write_targets? =
      Enum.any?(analyzers, fn {_key, entry} -> Map.has_key?(entry, "write_target") end)

    if has_write_targets? do
      updated =
        Map.new(analyzers, fn {key, entry} ->
          case entry do
            %{"write_target" => _} ->
              {key,
               Map.put(
                 entry,
                 "write_target",
                 %{
                   "resource" => to_string(record.__struct__),
                   "id" => to_string(Map.get(record, :id))
                 }
                 |> maybe_put_tenant(context_opts[:tenant])
               )}

            _ ->
              {key, entry}
          end
        end)

      Ash.update(
        blob,
        %{analyzers: updated},
        Keyword.merge(context_opts, action: :update_metadata)
      )
    end
  end

  defp extract_file_metadata(%Ash.Type.File{} = file) do
    {file_filename(file), file_content_type(file)}
  end

  defp extract_file_metadata(_) do
    {"upload", "application/octet-stream"}
  end

  defp file_filename(%Ash.Type.File{} = file) do
    if function_exported?(Ash.Type.File, :filename, 1) do
      case Ash.Type.File.filename(file) do
        {:ok, name} -> name
        _ -> "upload"
      end
    else
      "upload"
    end
  end

  defp file_content_type(%Ash.Type.File{} = file) do
    if function_exported?(Ash.Type.File, :content_type, 1) do
      case Ash.Type.File.content_type(file) do
        {:ok, type} -> type
        _ -> "application/octet-stream"
      end
    else
      "application/octet-stream"
    end
  end

  defp maybe_put_tenant(map, nil), do: map
  defp maybe_put_tenant(map, tenant), do: Map.put(map, "tenant", tenant)

  defp resolve_service(resource, attachment_def) do
    case Info.service_for_attachment(resource, attachment_def) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :no_service_configured}
    end
  end

  defp upload_and_create_blob(bctx, service_mod, service_opts, io, opts) do
    BlobIO.write(
      io,
      bctx,
      Keyword.merge(opts,
        service: {service_mod, service_opts}
      )
    )
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp maybe_replace_existing(
         record,
         %{type: :one} = attachment_def,
         service_mod,
         ctx,
         context_opts
       ) do
    case find_attachments(record, attachment_def, context_opts) do
      {:ok, []} -> {:ok, :noop}
      {:ok, existing} -> purge_attachments(existing, service_mod, ctx, context_opts)
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_replace_existing(_record, %{type: :many}, _service_mod, _ctx, _context_opts),
    do: {:ok, :noop}

  # sobelow_skip ["DOS.BinToAtom"]
  defp create_attachment(record, attachment_def, blob, context_opts) do
    resource = record.__struct__
    attachment_resource = Info.storage_attachment_resource!(resource)
    record_id = Map.get(record, :id) |> to_string()

    belongs_to_resources =
      Spark.Dsl.Extension.get_entities(attachment_resource, [:attachment])

    parent_rel = Enum.find(belongs_to_resources, fn bt -> bt.resource == resource end)

    params =
      if parent_rel do
        fk_attr = :"#{parent_rel.name}_id"

        Map.new([
          {:name, to_string(attachment_def.name)},
          {fk_attr, record_id},
          {:blob_id, blob.id}
        ])
      else
        %{
          name: to_string(attachment_def.name),
          record_type: to_string(resource),
          record_id: record_id,
          blob_id: blob.id
        }
      end

    Ash.create(attachment_resource, params, Keyword.merge(context_opts, action: :create))
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp find_attachments(record, attachment_def, context_opts) do
    resource = record.__struct__
    attachment_resource = Info.storage_attachment_resource!(resource)
    record_id = Map.get(record, :id) |> to_string()

    belongs_to_resources =
      Spark.Dsl.Extension.get_entities(attachment_resource, [:attachment])

    parent_rel = Enum.find(belongs_to_resources, fn bt -> bt.resource == resource end)

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
    |> Ash.Query.set_tenant(context_opts[:tenant])
    |> Ash.read(context_opts)
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
