defmodule AshStorage.Changes.HandleFileArgument do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Scope, Target}
  alias AshStorage.Service.Context

  @impl true
  def init(opts), do: {:ok, opts}

  # sobelow_skip ["DOS.BinToAtom"]
  @impl true
  def change(changeset, opts, context) do
    argument_name = opts[:argument]
    attachment_name = opts[:attachment]

    file = Ash.Changeset.get_argument(changeset, argument_name)

    if is_nil(file) do
      changeset
    else
      changeset
      |> Ash.Changeset.before_action(fn changeset ->
        scope = Scope.from_change(changeset, context)

        case upload_blob(changeset.resource, attachment_name, file, changeset, scope) do
          {:ok, attrs_to_write, state} ->
            changeset
            |> Ash.Changeset.force_change_attributes(attrs_to_write)
            |> Ash.Changeset.put_context(:"__ash_storage_file_arg_#{argument_name}__", state)

          {:error, error} ->
            Ash.Changeset.add_error(changeset, error)
        end
      end)
      |> Ash.Changeset.after_action(fn changeset, record ->
        context_key = :"__ash_storage_file_arg_#{argument_name}__"

        case changeset.context[context_key] do
          %{blob: blob, target: target} = state ->
            scope = Scope.from_change(changeset, context)

            # On update, replace existing attachment; on create, skip
            with {:ok, _} <- maybe_replace_on_update(changeset, record, target, scope),
                 {:ok, attachment} <- create_attachment(record, target.attachment, blob, scope) do
              # Now that we have the record ID, update write_target for oban analyzers
              if state[:has_oban_analyzers?] do
                update_oban_write_targets(blob, record, scope)
                AshOban.run_trigger(blob, :run_pending_analyzers, tenant: scope.tenant)
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

  defp maybe_replace_on_update(%{action_type: :create}, _record, _target, _scope) do
    {:ok, :noop}
  end

  defp maybe_replace_on_update(_changeset, record, target, scope) do
    maybe_replace_existing(record, target, scope)
  end

  defp upload_blob(resource, attachment_name, file, changeset, scope) do
    {filename, content_type} = extract_file_metadata(file)

    with {:ok, target} <- Pipeline.resolve(resource, attachment_name),
         {:ok, {service_mod, ctx}} <- Target.service_context(target, scope),
         {:ok, key} <- AshStorage.resolve_key(target.attachment, ctx, changeset),
         {:ok, blob} <-
           upload_and_create_blob(target, service_mod, ctx, file, scope,
             key: key,
             filename: filename,
             content_type: content_type
           ),
         {:ok, blob, attrs_to_write} <-
           run_analyzers(blob, target.attachment, changeset.data, file, scope) do
      {:ok, attrs_to_write,
       %{
         blob: blob,
         target: target,
         has_oban_analyzers?: has_oban_analyzers?(target.attachment)
       }}
    end
  end

  # After create, we have the real record ID — update write_target in blob's analyzers map
  defp update_oban_write_targets(blob, record, scope) do
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
                 |> maybe_put_tenant(scope.tenant)
               )}

            _ ->
              {key, entry}
          end
        end)

      Ash.update(
        blob,
        %{analyzers: updated},
        Scope.to_opts(scope, action: :update_metadata)
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

  # -- Shared helpers (same as Changes.Attach) --

  defp has_oban_analyzers?(attachment_def) do
    Enum.any?(attachment_def.analyzers || [], fn defn -> defn.analyze == :oban end)
  end

  defp run_analyzers(blob, attachment_def, record, io, scope) do
    analyzer_defs = attachment_def.analyzers || []

    if analyzer_defs == [] do
      {:ok, blob, %{}}
    else
      normalized = AshStorage.AttachmentDefinition.normalize_analyzers(analyzer_defs)
      content_type = blob.content_type || "application/octet-stream"

      initial_analyzers =
        Map.new(normalized, fn {module, _analyze, opts, write_attributes} ->
          string_opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

          entry =
            %{"status" => "pending", "opts" => string_opts}
            |> maybe_put_tenant(scope.tenant)

          entry =
            if write_attributes != [] do
              string_wa =
                Map.new(write_attributes, fn {k, v} -> {to_string(k), to_string(v)} end)

              entry
              |> Map.put("write_attributes", string_wa)
              |> Map.put(
                "write_target",
                %{
                  "resource" => to_string(record.__struct__),
                  "id" => to_string(Map.get(record, :id))
                }
                |> maybe_put_tenant(scope.tenant)
              )
            else
              entry
            end

          {to_string(module), entry}
        end)

      with {:ok, blob} <-
             Ash.update(
               blob,
               %{analyzers: initial_analyzers},
               Scope.to_opts(scope, action: :update_metadata)
             ) do
        eager =
          Enum.filter(normalized, fn {module, analyze, _opts, _wa} ->
            analyze != :oban && module.accept?(content_type)
          end)

        run_eager_analyzers(blob, eager, io, scope)
      end
    end
  end

  defp run_eager_analyzers(blob, [], _io, _scope), do: {:ok, blob, %{}}

  defp run_eager_analyzers(blob, eager_analyzers, io, scope) do
    {:ok, path} = resolve_analyzer_path(io)

    try do
      Enum.reduce_while(eager_analyzers, {:ok, blob, %{}}, fn {module, _analyze, opts,
                                                               write_attributes},
                                                              {:ok, blob, acc_writes} ->
        analyzer_key = to_string(module)

        {status, metadata_to_merge} =
          case module.analyze(path, opts) do
            {:ok, result} -> {"complete", result}
            {:error, _reason} -> {"error", %{}}
          end

        new_writes =
          if status == "complete" && write_attributes != [] do
            Enum.reduce(write_attributes, %{}, fn {result_key, attr_name}, acc ->
              case Map.fetch(metadata_to_merge, to_string(result_key)) do
                {:ok, value} -> Map.put(acc, attr_name, value)
                :error -> acc
              end
            end)
          else
            %{}
          end

        case Ash.update(
               blob,
               %{
                 analyzer_key: analyzer_key,
                 status: status,
                 metadata_to_merge: metadata_to_merge
               },
               Scope.to_opts(scope, action: :complete_analysis)
             ) do
          {:ok, blob} -> {:cont, {:ok, blob, Map.merge(acc_writes, new_writes)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    after
      maybe_cleanup_tempfile(io, path)
    end
  end

  defp maybe_put_tenant(map, nil), do: map
  defp maybe_put_tenant(map, tenant), do: Map.put(map, "tenant", tenant)

  # sobelow_skip ["Crypto.WeakHash"]
  defp upload_and_create_blob(target, service_mod, ctx, io, scope, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    data = read_io(io)
    key = Keyword.fetch!(opts, :key)
    checksum = :crypto.hash(:md5, data) |> Base.encode64()
    byte_size = byte_size(data)

    # See `AshStorage.Changes.Attach.upload_and_create_blob/6` for the
    # rationale on threading the blob's content_type / filename into the
    # context before calling `service_mod.upload/3`.
    ctx =
      ctx
      |> Context.put_expected_md5(checksum)
      |> Context.put_blob_metadata(content_type: content_type, filename: filename)

    with {:ok, extra_blob_attrs} <- normalize_upload(service_mod.upload(key, data, ctx)) do
      blob_attrs =
        %{
          key: key,
          filename: filename,
          content_type: content_type,
          byte_size: byte_size,
          checksum: checksum,
          service_name: service_mod,
          service_opts: Target.persistable_service_opts(service_mod, ctx.service_opts),
          metadata: %{}
        }
        |> Map.merge(extra_blob_attrs)

      Ash.create(target.blob_resource, blob_attrs, Scope.to_opts(scope, action: :create))
    end
  end

  defp normalize_upload(:ok), do: {:ok, %{}}
  defp normalize_upload({:ok, attrs}) when is_map(attrs), do: {:ok, attrs}
  defp normalize_upload({:error, _} = error), do: error

  defp read_io(%Ash.Type.File{} = file) do
    {:ok, device} = Ash.Type.File.open(file, [:read, :binary])
    data = IO.binread(device, :eof)
    File.close(device)
    data
  end

  defp read_io(%File.Stream{} = stream), do: Enum.into(stream, <<>>, &IO.iodata_to_binary/1)

  # See `AshStorage.Changes.Attach.read_io/1` for the rationale on this
  # clause and the full input contract.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp read_io(%{__struct__: Plug.Upload, path: path}) when is_binary(path),
    do: File.read!(path)

  defp read_io(data) when is_binary(data), do: data
  defp read_io(data) when is_list(data), do: IO.iodata_to_binary(data)

  defp resolve_analyzer_path(%Ash.Type.File{} = file) do
    case Ash.Type.File.path(file) do
      {:ok, path} -> {:ok, path}
      _ -> write_tempfile(file)
    end
  end

  defp resolve_analyzer_path(%File.Stream{path: path}), do: {:ok, path}

  defp resolve_analyzer_path(data) when is_binary(data) or is_list(data) do
    write_tempfile(data)
  end

  defp write_tempfile(%Ash.Type.File{} = file) do
    {:ok, device} = Ash.Type.File.open(file, [:read, :binary])
    data = IO.binread(device, :eof)
    File.close(device)
    write_tempfile(data)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_tempfile(data) when is_binary(data) do
    path = Path.join(System.tmp_dir!(), "ash_storage_analyze_#{AshStorage.generate_key()}")
    File.write!(path, data)
    {:ok, path}
  end

  defp write_tempfile(data) when is_list(data), do: write_tempfile(IO.iodata_to_binary(data))

  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_cleanup_tempfile(%Ash.Type.File{} = file, path) do
    case Ash.Type.File.path(file) do
      {:ok, ^path} -> :ok
      _ -> File.rm(path)
    end
  end

  defp maybe_cleanup_tempfile(%File.Stream{}, _path), do: :ok
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_cleanup_tempfile(_data, path), do: File.rm(path)

  defp maybe_replace_existing(record, %Target{attachment: %{type: :one}} = target, scope) do
    with {:ok, {service_mod, ctx}} <- Target.service_context(target, scope) do
      case find_attachments(record, target.attachment, scope) do
        {:ok, []} -> {:ok, :noop}
        {:ok, existing} -> purge_attachments(existing, service_mod, ctx, scope)
        {:error, _} = error -> error
      end
    end
  end

  defp maybe_replace_existing(_record, %Target{attachment: %{type: :many}}, _scope),
    do: {:ok, :noop}

  # sobelow_skip ["DOS.BinToAtom"]
  defp create_attachment(record, attachment_def, blob, scope) do
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

    Ash.create(attachment_resource, params, Scope.to_opts(scope, action: :create))
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp find_attachments(record, attachment_def, scope) do
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
