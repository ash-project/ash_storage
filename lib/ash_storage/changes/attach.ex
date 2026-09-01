defmodule AshStorage.Changes.Attach do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.BlobIO
  alias AshStorage.Changes.AnalyzerRun
  alias AshStorage.Info

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
              AshOban.run_trigger(blob, :run_pending_analyzers, tenant: changeset.tenant)
            end

            if has_oban_variants?(attachment_def) do
              AshOban.run_trigger(blob, :run_pending_variants, tenant: changeset.tenant)
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
    context_opts = Keyword.put(context_opts, :tenant, changeset.tenant)
    io = Ash.Changeset.get_argument(changeset, :io)
    filename = Ash.Changeset.get_argument(changeset, :filename)

    content_type =
      Ash.Changeset.get_argument(changeset, :content_type) || "application/octet-stream"

    metadata = Ash.Changeset.get_argument(changeset, :metadata) || %{}

    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
         {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def) do
      bctx =
        BlobIO.BlobContext.from_changeset(changeset, attachment_def,
          operation: :attach,
          record: record
        )

      service_ctx = BlobIO.BlobContext.to_service_context(bctx, service_opts)
      key = AshStorage.resolve_key(attachment_def, service_ctx, changeset)

      with {:ok, blob} <-
             upload_and_create_blob(bctx, service_mod, service_opts, io, context_opts,
               key: key,
               filename: filename,
               content_type: content_type,
               metadata: metadata
             ),
           {:ok, blob, attrs_to_write} <-
             AnalyzerRun.run_analyzers(blob, attachment_def, record, io,
               Keyword.merge(context_opts, flag_pending_analyzers?: true)
             ) do
        {:ok, attrs_to_write,
         %{
           blob: blob,
           attachment_def: attachment_def,
           service_mod: service_mod,
           ctx: service_ctx,
           context_opts: context_opts,
           has_oban_analyzers?: AnalyzerRun.has_oban_analyzers?(attachment_def)
         }}
      end
    end
  end

  # -- Service helpers --

  defp resolve_service(resource, attachment_def) do
    case Info.service_for_attachment(resource, attachment_def) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :no_service_configured}
    end
  end

  defp upload_and_create_blob(bctx, service_mod, service_opts, io, context_opts, opts) do
    BlobIO.write(
      io,
      bctx,
      Keyword.merge(opts,
        service: {service_mod, service_opts},
        ash_opts: context_opts
      )
    )
  end

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
