defmodule AshStorage.Operations do
  @moduledoc """
  Core operations for managing file attachments.

  These functions handle the lifecycle of attachments: uploading files,
  creating blob and attachment records, detaching, and purging.
  """

  require Ash.Query

  alias AshStorage.Resource.Info

  @doc """
  Attach a file to a record.

  Uploads the file to the storage service, creates a blob record, and creates
  an attachment record linking the blob to the record.

  For `has_one_attached`, any existing attachment with the same name is replaced
  (the old blob and file are purged).

  For `has_many_attached`, the new attachment is appended.

  ## Options

  - `:filename` - (required) the original filename
  - `:content_type` - MIME type of the file (default: `"application/octet-stream"`)
  - `:metadata` - additional metadata map to store on the blob

  ## Examples

      AshStorage.Operations.attach(post, :cover_image, file_data,
        filename: "photo.jpg",
        content_type: "image/jpeg"
      )
  """
  def attach(record, attachment_name, io, opts \\ []) do
    resource = record.__struct__

    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
         {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def),
         {:ok, blob} <- upload_and_create_blob(resource, service_mod, service_opts, io, opts),
         {:ok, _} <- maybe_replace_existing(record, attachment_def),
         {:ok, attachment} <- create_attachment(record, attachment_def, blob) do
      {:ok, %{blob: blob, attachment: attachment}}
    end
  end

  @doc """
  Detach an attachment from a record without deleting the blob or file.

  For `has_one_attached`, removes the single attachment.
  For `has_many_attached`, removes the attachment matching the given blob ID.

  ## Options

  - `:blob_id` - (required for `has_many_attached`) which attachment to detach
  """
  def detach(record, attachment_name, opts \\ []) do
    resource = record.__struct__

    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
         {:ok, attachments} <- find_attachments(record, attachment_def),
         {:ok, to_detach} <- select_for_detach(attachments, attachment_def, opts) do
      destroy_attachment_records(to_detach, resource)
    end
  end

  @doc """
  Purge an attachment: destroy the attachment record, blob record, and file from storage.

  For `has_one_attached`, purges the single attachment.
  For `has_many_attached`, purges the attachment matching the given blob ID,
  or all attachments if `:all` is passed.

  ## Options

  - `:blob_id` - (required for `has_many_attached` unless `:all` is true) which attachment to purge
  - `:all` - purge all attachments for this name (default: `false`)
  """
  def purge(record, attachment_name, opts \\ []) do
    resource = record.__struct__

    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
         {:ok, attachments} <- find_attachments(record, attachment_def),
         {:ok, to_purge} <- select_for_purge(attachments, attachment_def, opts),
         {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def) do
      purge_attachments(to_purge, resource, service_mod, service_opts)
    end
  end

  # -- Private helpers --

  defp resolve_service(resource, attachment_def) do
    case Info.service_for_attachment(resource, attachment_def) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :no_service_configured}
    end
  end

  defp upload_and_create_blob(resource, service_mod, service_opts, io, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    metadata = Keyword.get(opts, :metadata, %{})

    data = read_io(io)
    key = AshStorage.generate_key()
    checksum = :crypto.hash(:md5, data) |> Base.encode64()
    byte_size = byte_size(data)

    with :ok <- service_mod.upload(key, data, service_opts) do
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
          metadata: metadata
        },
        action: :create
      )
    end
  end

  defp read_io(%File.Stream{} = stream), do: Enum.into(stream, <<>>, &IO.iodata_to_binary/1)
  defp read_io(data) when is_binary(data), do: data
  defp read_io(data) when is_list(data), do: IO.iodata_to_binary(data)

  defp maybe_replace_existing(record, %{type: :one} = attachment_def) do
    case find_attachments(record, attachment_def) do
      {:ok, []} ->
        {:ok, :noop}

      {:ok, existing} ->
        resource = record.__struct__
        {service_mod, service_opts} = resolve_service!(resource, attachment_def)
        purge_attachments(existing, resource, service_mod, service_opts)
    end
  end

  defp maybe_replace_existing(_record, %{type: :many}), do: {:ok, :noop}

  defp resolve_service!(resource, attachment_def) do
    {:ok, service} = resolve_service(resource, attachment_def)
    service
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp create_attachment(record, attachment_def, blob) do
    resource = record.__struct__
    attachment_resource = Info.storage_attachment_resource!(resource)

    record_id = Map.get(record, :id) |> to_string()

    belongs_to_resources =
      Spark.Dsl.Extension.get_entities(attachment_resource, [:attachment])

    params =
      if belongs_to_resources == [] do
        %{
          name: to_string(attachment_def.name),
          record_type: to_string(resource),
          record_id: record_id,
          blob_id: blob.id
        }
      else
        parent_rel =
          Enum.find(belongs_to_resources, fn bt ->
            bt.resource == resource
          end)

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
      end

    Ash.create(attachment_resource, params, action: :create)
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp find_attachments(record, attachment_def) do
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
    |> Ash.read()
  end

  defp select_for_detach(attachments, %{type: :one}, _opts), do: {:ok, attachments}

  defp select_for_detach(attachments, %{type: :many}, opts) do
    case Keyword.fetch(opts, :blob_id) do
      {:ok, blob_id} ->
        {:ok, Enum.filter(attachments, &(&1.blob_id == blob_id))}

      :error ->
        {:error, :blob_id_required_for_has_many}
    end
  end

  defp select_for_purge(attachments, %{type: :one}, _opts), do: {:ok, attachments}

  defp select_for_purge(attachments, %{type: :many}, opts) do
    if Keyword.get(opts, :all, false) do
      {:ok, attachments}
    else
      case Keyword.fetch(opts, :blob_id) do
        {:ok, blob_id} ->
          {:ok, Enum.filter(attachments, &(&1.blob_id == blob_id))}

        :error ->
          {:error, :blob_id_required_for_has_many}
      end
    end
  end

  defp destroy_attachment_records(attachments, _resource) do
    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
      case Ash.destroy(att, action: :destroy, return_destroyed?: true) do
        {:ok, destroyed} -> {:cont, {:ok, [destroyed | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp purge_attachments(attachments, _resource, service_mod, service_opts) do
    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
      blob = att.blob

      with :ok <- delete_from_service(service_mod, service_opts, blob.key),
           {:ok, _} <- Ash.destroy(att, action: :destroy, return_destroyed?: true),
           {:ok, _} <- Ash.destroy(blob, action: :destroy, return_destroyed?: true) do
        {:cont, {:ok, [att | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp delete_from_service(service_mod, service_opts, key) do
    if function_exported?(service_mod, :delete, 2) do
      service_mod.delete(key, service_opts)
    else
      service_mod.delete(key)
    end
  end
end
