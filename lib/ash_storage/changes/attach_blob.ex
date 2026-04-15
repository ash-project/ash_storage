defmodule AshStorage.Changes.AttachBlob do
  @moduledoc """
  An action change that attaches a pre-uploaded blob (by ID) to the record.

  Used for direct uploads where the file was uploaded directly to storage
  (e.g. via a presigned S3 URL) and the blob record already exists.

      create :create do
        accept [:title]
        argument :cover_image_blob_id, :uuid, allow_nil?: true

        change {AshStorage.Changes.AttachBlob,
                argument: :cover_image_blob_id, attachment: :cover_image}
      end

  For `has_one_attached`, replaces any existing attachment (purging the old file).
  For `has_many_attached`, appends.

  ## Options

  - `:argument` - (required) the name of the blob ID argument on the action
  - `:attachment` - (required) the name of the attachment to attach to
  """
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Service.Context

  @impl true
  def init(opts) do
    with :ok <- validate_opt(opts, :argument),
         :ok <- validate_opt(opts, :attachment) do
      {:ok, opts}
    end
  end

  defp validate_opt(opts, key) do
    if opts[key], do: :ok, else: {:error, "#{key} is required"}
  end

  # sobelow_skip ["DOS.BinToAtom"]
  @impl true
  def change(changeset, opts, context) do
    argument_name = opts[:argument]
    attachment_name = opts[:attachment]

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      blob_id = Ash.Changeset.get_argument(changeset, argument_name)

      if is_nil(blob_id) do
        {:ok, record}
      else
        resource = record.__struct__
        context_opts = Ash.Context.to_opts(context)

        with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
             {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def),
             ctx = build_context(service_opts, resource, attachment_def, changeset),
             {:ok, blob} <- fetch_blob(resource, blob_id, context_opts),
             {:ok, _} <-
               maybe_replace_existing(record, attachment_def, service_mod, ctx, context_opts),
             {:ok, attachment} <-
               create_attachment(record, attachment_def, blob, context_opts) do
          record =
            record
            |> Ash.Resource.put_metadata(:"#{attachment_name}_blob", blob)
            |> Ash.Resource.put_metadata(:"#{attachment_name}_attachment", attachment)

          {:ok, record}
        end
      end
    end)
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

  defp fetch_blob(resource, blob_id, context_opts) do
    blob_resource = Info.storage_blob_resource!(resource)

    case Ash.get(blob_resource, blob_id, context_opts) do
      {:ok, blob} -> {:ok, blob}
      {:error, _} -> {:error, :blob_not_found}
    end
  end

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
end
