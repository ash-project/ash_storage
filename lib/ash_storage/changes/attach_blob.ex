defmodule AshStorage.Changes.AttachBlob do
  @moduledoc """
  An action change that attaches a pre-uploaded blob (by ID) to the record.

  Used for direct uploads where the file was uploaded directly to storage
  (e.g. via an S3 presigned URL or Azure Blob SAS URL) and the blob record already
  exists.

      create :create do
        accept [:title]
        argument :cover_image_blob_id, :uuid, allow_nil?: true

        change {AshStorage.Changes.AttachBlob,
                argument: :cover_image_blob_id, attachment: :cover_image}
      end

  For `has_one_attached`, replaces any existing attachment (purging the old file).
  For `has_many_attached`, appends. Attaching a blob that is already attached is
  a no-op.

  ## Options

  - `:argument` - (required) the name of the blob ID argument on the action
  - `:attachment` - (required) the name of the attachment to attach to
  """
  use Ash.Resource.Change

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Scope, Target}

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

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      blob_id = Ash.Changeset.get_argument(changeset, argument_name)

      if is_nil(blob_id) do
        {:ok, record}
      else
        scope = Scope.from_change(changeset, context)

        with {:ok, target} <- Pipeline.resolve(record.__struct__, attachment_name),
             {:ok, {service_mod, ctx}} <- Target.service_context(target, scope),
             {:ok, blob} <- fetch_blob(target, blob_id, scope),
             {:ok, existing} <- find_attachments(record, target.attachment, blob, scope),
             {:ok, blob, attachment} <-
               attach(record, target.attachment, blob, existing, service_mod, ctx, scope) do
          record =
            record
            |> Ash.Resource.put_metadata(:"#{attachment_name}_blob", blob)
            |> Ash.Resource.put_metadata(:"#{attachment_name}_attachment", attachment)

          {:ok, record}
        end
      end
    end)
  end

  defp fetch_blob(target, blob_id, scope) do
    case Ash.get(target.blob_resource, blob_id, Scope.to_opts(scope)) do
      {:ok, blob} -> {:ok, blob}
      {:error, _} -> {:error, :blob_not_found}
    end
  end

  defp verify_blob(blob, service_mod, ctx, scope) do
    with :ok <- if(exports_head?(service_mod), do: :ok, else: {:ok, blob}),
         {:ok, info} <- service_mod.head(blob.key, ctx) do
      service_md5 = service_md5(info)

      case presence(blob.checksum) do
        ^service_md5 ->
          {:ok, blob}

        nil ->
          blob
          |> Ash.Changeset.for_update(:update_metadata, %{}, Scope.to_opts(scope))
          |> Ash.Changeset.force_change_attribute(:checksum, service_md5)
          |> Ash.update(Scope.to_opts(scope))

        _ when is_nil(service_md5) ->
          {:error, :checksum_unverifiable}

        _ ->
          {:error, :checksum_mismatch}
      end
    end
  end

  defp exports_head?(service_mod) do
    Code.ensure_loaded?(service_mod) and function_exported?(service_mod, :head, 2)
  end

  defp service_md5(%{content_md5: md5}) when is_binary(md5), do: md5

  defp service_md5(%{etag: etag}) when is_binary(etag) do
    case etag |> String.trim("\"") |> Base.decode16(case: :lower) do
      {:ok, raw} when byte_size(raw) == 16 -> Base.encode64(raw)
      _ -> nil
    end
  end

  defp service_md5(_), do: nil

  defp presence(value) when value in [nil, ""], do: nil
  defp presence(value), do: value

  # Attaching the blob that is already attached is a no-op, so that e.g. a form
  # sending back the current blob id doesn't purge the file it points to.
  defp attach(record, attachment_def, blob, existing, service_mod, ctx, scope) do
    case Enum.split_with(existing, &(&1.blob_id == blob.id)) do
      {[attachment | _], others} ->
        with {:ok, _} <-
               maybe_replace_existing(others, attachment_def, service_mod, ctx, scope) do
          {:ok, blob, attachment}
        end

      {[], others} ->
        with {:ok, blob} <- verify_blob(blob, service_mod, ctx, scope),
             {:ok, _} <-
               maybe_replace_existing(others, attachment_def, service_mod, ctx, scope),
             {:ok, attachment} <- create_attachment(record, attachment_def, blob, scope) do
          {:ok, blob, attachment}
        end
    end
  end

  defp maybe_replace_existing([], _attachment_def, _service_mod, _ctx, _scope),
    do: {:ok, :noop}

  defp maybe_replace_existing(existing, %{type: :one}, service_mod, ctx, scope),
    do: purge_attachments(existing, service_mod, ctx, scope)

  defp maybe_replace_existing(_existing, %{type: :many}, _service_mod, _ctx, _scope),
    do: {:ok, :noop}

  # sobelow_skip ["DOS.BinToAtom"]
  defp create_attachment(record, attachment_def, blob, scope) do
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

    Ash.create(attachment_resource, params, Scope.to_opts(scope, action: :create))
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp find_attachments(record, attachment_def, blob, scope) do
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

    # has_many appends, so only an existing attachment of this blob matters
    filter =
      case attachment_def.type do
        :one -> filter
        :many -> [{:blob_id, blob.id} | filter]
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
