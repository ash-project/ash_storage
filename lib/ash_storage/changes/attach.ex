defmodule AshStorage.Changes.Attach do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Service.Context

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, opts, context) do
    attachment_name = opts[:attachment_name]
    context_opts = Ash.Context.to_opts(context)

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      record = changeset.data
      resource = record.__struct__

      case do_attach(record, resource, attachment_name, changeset, context_opts) do
        {:ok, attrs_to_write, attach_context} ->
          changeset
          |> Ash.Changeset.force_change_attributes(attrs_to_write)
          |> Ash.Changeset.put_context(:__ash_storage_attach__, attach_context)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      case changeset.context[:__ash_storage_attach__] do
        %{
          blob: blob,
          attachment_def: attachment_def,
          service_mod: service_mod,
          ctx: ctx,
          context_opts: context_opts
        } = attach_context ->
          resource = record.__struct__

          with {:ok, _} <-
                 maybe_replace_existing(record, attachment_def, service_mod, ctx, context_opts),
               {:ok, attachment} <-
                 create_attachment(record, attachment_def, blob, context_opts),
               :ok <- run_eager_variants(blob, attachment_def, resource),
               {:ok, blob} <- store_oban_variants(blob, attachment_def, resource) do
            if attach_context[:has_oban_analyzers?] do
              AshOban.run_trigger(blob, :run_pending_analyzers)
            end

            if has_oban_variants?(attachment_def) do
              AshOban.run_trigger(blob, :run_pending_variants)
            end

            record =
              record
              |> Ash.Resource.put_metadata(:blob, blob)
              |> Ash.Resource.put_metadata(:attachment, attachment)

            {:ok, record}
          end

        _ ->
          {:ok, record}
      end
    end)
  end

  defp do_attach(record, resource, attachment_name, changeset, context_opts) do
    io = Ash.Changeset.get_argument(changeset, :io)
    filename = Ash.Changeset.get_argument(changeset, :filename)

    content_type =
      Ash.Changeset.get_argument(changeset, :content_type) || "application/octet-stream"

    metadata = Ash.Changeset.get_argument(changeset, :metadata) || %{}

    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
         {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def) do
      ctx = build_context(service_opts, resource, attachment_def, changeset)

      with {:ok, blob} <-
             upload_and_create_blob(resource, service_mod, ctx, io, context_opts,
               filename: filename,
               content_type: content_type,
               metadata: metadata
             ),
           {:ok, blob, attrs_to_write} <- run_analyzers(blob, attachment_def, record, io) do
        {:ok, attrs_to_write,
         %{
           blob: blob,
           attachment_def: attachment_def,
           service_mod: service_mod,
           ctx: ctx,
           context_opts: context_opts,
           has_oban_analyzers?: has_oban_analyzers?(attachment_def)
         }}
      end
    end
  end

  defp has_oban_analyzers?(attachment_def) do
    analyzer_defs = attachment_def.analyzers || []

    Enum.any?(analyzer_defs, fn defn ->
      defn.analyze == :oban
    end)
  end

  defp run_analyzers(blob, attachment_def, record, io) do
    analyzer_defs = attachment_def.analyzers || []

    if analyzer_defs == [] do
      {:ok, blob, %{}}
    else
      normalized = AshStorage.AttachmentDefinition.normalize_analyzers(analyzer_defs)
      content_type = blob.content_type || "application/octet-stream"

      initial_analyzers =
        Map.new(normalized, fn {module, _analyze, opts, write_attributes} ->
          string_opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

          entry = %{"status" => "pending", "opts" => string_opts}

          entry =
            if write_attributes != [] do
              string_wa =
                Map.new(write_attributes, fn {k, v} -> {to_string(k), to_string(v)} end)

              entry
              |> Map.put("write_attributes", string_wa)
              |> Map.put("write_target", %{
                "resource" => to_string(record.__struct__),
                "id" => to_string(Map.get(record, :id))
              })
            else
              entry
            end

          {to_string(module), entry}
        end)

      has_oban? = Enum.any?(normalized, fn {_, analyze, _, _} -> analyze == :oban end)

      update_params =
        %{analyzers: initial_analyzers}
        |> then(fn params ->
          if has_oban?, do: Map.put(params, :pending_analyzers, true), else: params
        end)

      with {:ok, blob} <-
             Ash.update(blob, update_params, action: :update_metadata) do
        eager =
          Enum.filter(normalized, fn {module, analyze, _opts, _wa} ->
            analyze != :oban && module.accept?(content_type)
          end)

        run_eager_analyzers(blob, eager, io)
      end
    end
  end

  defp run_eager_analyzers(blob, [], _io), do: {:ok, blob, %{}}

  defp run_eager_analyzers(blob, eager_analyzers, io) do
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
               action: :complete_analysis
             ) do
          {:ok, blob} -> {:cont, {:ok, blob, Map.merge(acc_writes, new_writes)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    after
      maybe_cleanup_tempfile(io, path)
    end
  end

  # -- Service helpers --

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

  defp persistable_service_opts(service_mod, service_opts) do
    if function_exported?(service_mod, :service_opts_fields, 0) do
      fields = service_mod.service_opts_fields()
      field_names = Keyword.keys(fields)

      service_opts
      |> Keyword.take(field_names)
      |> Map.new()
    else
      %{}
    end
  end

  defp upload_and_create_blob(resource, service_mod, ctx, io, context_opts, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    metadata = Keyword.get(opts, :metadata, %{})

    data = read_io(io)
    key = AshStorage.generate_key()
    checksum = :crypto.hash(:md5, data) |> Base.encode64()
    byte_size = byte_size(data)

    with :ok <- service_mod.upload(key, data, ctx) do
      blob_resource = Info.storage_blob_resource!(resource)

      Ash.create(
        blob_resource,
        %{
          key: key,
          filename: filename,
          content_type: content_type,
          byte_size: byte_size,
          checksum: checksum,
          service_name: service_mod,
          service_opts: persistable_service_opts(service_mod, ctx.service_opts),
          metadata: metadata
        },
        Keyword.merge(context_opts, action: :create)
      )
    end
  end

  # -- IO helpers --

  defp read_io(%Ash.Type.File{} = file) do
    {:ok, device} = Ash.Type.File.open(file, [:read, :binary])
    data = IO.binread(device, :eof)
    File.close(device)
    data
  end

  defp read_io(%File.Stream{} = stream), do: Enum.into(stream, <<>>, &IO.iodata_to_binary/1)
  defp read_io(data) when is_binary(data), do: data
  defp read_io(data) when is_list(data), do: IO.iodata_to_binary(data)

  # -- Analyzer IO helpers --

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

  defp write_tempfile(data) when is_list(data) do
    write_tempfile(IO.iodata_to_binary(data))
  end

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

  # -- Attachment helpers --

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

    parent_rel =
      Enum.find(belongs_to_resources, fn bt ->
        bt.resource == resource
      end)

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
    |> Ash.Query.set_tenant(context_opts[:tenant])
    |> Ash.read()
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

  # -- Variant helpers --

  defp run_eager_variants(blob, attachment_def, resource) do
    eager_variants =
      (attachment_def.variants || [])
      |> Enum.filter(&(&1.generate == :eager))

    Enum.reduce_while(eager_variants, :ok, fn variant_def, :ok ->
      case AshStorage.VariantGenerator.generate(blob, variant_def, resource, attachment_def) do
        {:ok, _variant_blob} -> {:cont, :ok}
        {:error, :not_accepted} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp has_oban_variants?(attachment_def) do
    (attachment_def.variants || [])
    |> Enum.any?(&(&1.generate == :oban))
  end

  defp store_oban_variants(blob, attachment_def, resource) do
    oban_variants =
      (attachment_def.variants || [])
      |> Enum.filter(&(&1.generate == :oban))

    if oban_variants == [] do
      {:ok, blob}
    else
      pending_variants =
        Map.new(oban_variants, fn variant_def ->
          {mod, opts} = AshStorage.VariantDefinition.normalize(variant_def)
          string_opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

          {to_string(variant_def.name),
           %{
             "status" => "pending",
             "module" => to_string(mod),
             "opts" => string_opts,
             "resource" => to_string(resource),
             "attachment" => to_string(attachment_def.name)
           }}
        end)

      metadata = Map.put(blob.metadata || %{}, "__pending_variants__", pending_variants)

      Ash.update(blob, %{metadata: metadata, pending_variants: true}, action: :update_metadata)
    end
  end
end
