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

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Hooks, Scope, Target}

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
    nested? = Hooks.nested?(changeset)

    changeset
    |> Ash.Changeset.after_action(fn changeset, record ->
      blob_id = Ash.Changeset.get_argument(changeset, argument_name)

      if is_nil(blob_id) do
        {:ok, record}
      else
        scope = Scope.from_change(changeset, context)

        with {:ok, target} <- Pipeline.resolve(record.__struct__, attachment_name),
             {:ok, {service_mod, ctx}} <- Target.service_context(target, scope),
             {:ok, blob} <- fetch_blob(target, blob_id, scope),
             {:ok, existing} <- existing_attachments(record, target, blob, scope),
             {:ok, blob, attachment, deletions} <-
               attach(record, target, blob, existing, service_mod, ctx, scope) do
          record =
            record
            |> Ash.Resource.put_metadata(:"#{attachment_name}_blob", blob)
            |> Ash.Resource.put_metadata(:"#{attachment_name}_attachment", attachment)
            |> Hooks.defer_deletions(deletions, nested?)

          {:ok, record}
        end
      end
    end)
    |> Hooks.delete_after_transaction(nested?)
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
  defp attach(record, target, blob, existing, service_mod, ctx, scope) do
    case Enum.split_with(existing, &(&1.blob_id == blob.id)) do
      {[attachment | _], others} ->
        with {:ok, deletions} <- replace_others(others, target, scope) do
          {:ok, blob, attachment, deletions}
        end

      {[], others} ->
        with {:ok, blob} <- verify_blob(blob, service_mod, ctx, scope),
             {:ok, deletions} <- replace_others(others, target, scope),
             {:ok, attachment} <- Pipeline.insert_attachment(record, blob, target, scope) do
          {:ok, blob, attachment, deletions}
        end
    end
  end

  # Replacing a has_one file removes the old one through the shared purge; the
  # old files are deleted once the transaction has committed.
  defp replace_others(others, %Target{attachment: %{type: :one}} = target, scope) do
    with {:ok, %{deletions: deletions}} <- Pipeline.unlink(others, :purge, target, scope) do
      {:ok, deletions}
    end
  end

  defp replace_others(_others, %Target{attachment: %{type: :many}}, _scope), do: {:ok, []}

  # has_many appends, so only an existing attachment of this blob matters
  defp existing_attachments(record, %Target{attachment: %{type: :one}} = target, _blob, scope),
    do: Pipeline.attachments(record, target, scope)

  defp existing_attachments(record, %Target{attachment: %{type: :many}} = target, blob, scope),
    do: Pipeline.attachments(record, target, scope, blob_id: blob.id)
end
