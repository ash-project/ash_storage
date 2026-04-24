defmodule AshStorage.VariantGenerator do
  @moduledoc false

  alias AshStorage.Info
  alias AshStorage.Service.Context
  alias AshStorage.VariantDefinition

  @doc """
  Generate a variant blob from a source blob.

  Downloads the source, runs the transform, uploads the result, and creates a variant blob record.
  Returns `{:ok, variant_blob}` or `{:error, reason}`.
  """
  def generate(source_blob, variant_def, resource, attachment_def) do
    {module, opts} = VariantDefinition.normalize(variant_def)
    digest = VariantDefinition.digest(variant_def)
    content_type = source_blob.content_type || "application/octet-stream"

    if module.accept?(content_type) do
      do_generate(source_blob, module, opts, digest, variant_def.name, resource, attachment_def)
    else
      {:error, :not_accepted}
    end
  end

  defp do_generate(source_blob, module, opts, digest, variant_name, resource, attachment_def) do
    with {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def),
         {:ok, source_data} <-
           download_source(source_blob, service_mod, service_opts, resource, attachment_def),
         {:ok, transform_result, variant_data} <- run_transform(module, opts, source_data) do
      upload_and_create_variant(
        source_blob,
        variant_name,
        digest,
        transform_result,
        variant_data,
        resource,
        service_mod,
        service_opts,
        attachment_def
      )
    end
  end

  defp download_source(source_blob, service_mod, service_opts, resource, attachment_def) do
    ctx =
      Context.new(service_opts,
        resource: resource,
        attachment: attachment_def
      )

    service_mod.download(source_blob.key, ctx)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp run_transform(module, opts, source_data) do
    source_path =
      Path.join(System.tmp_dir!(), "ash_storage_variant_src_#{AshStorage.generate_key()}")

    dest_path =
      Path.join(System.tmp_dir!(), "ash_storage_variant_dst_#{AshStorage.generate_key()}")

    File.write!(source_path, source_data)

    try do
      case module.transform(source_path, dest_path, opts) do
        {:ok, metadata} ->
          variant_data = File.read!(dest_path)
          {:ok, metadata, variant_data}

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm(source_path)
      File.rm(dest_path)
    end
  end

  defp upload_and_create_variant(
         source_blob,
         variant_name,
         digest,
         transform_metadata,
         variant_data,
         resource,
         service_mod,
         service_opts,
         attachment_def
       ) do
    key = AshStorage.generate_key()
    checksum = :crypto.hash(:md5, variant_data) |> Base.encode64()
    byte_size = byte_size(variant_data)

    variant_content_type =
      Map.get(transform_metadata, :content_type, source_blob.content_type)

    variant_filename =
      Map.get(transform_metadata, :filename, "#{variant_name}_#{source_blob.filename}")

    extra_metadata =
      transform_metadata
      |> Map.drop([:content_type, :filename])

    ctx =
      Context.new(service_opts,
        resource: resource,
        attachment: attachment_def
      )

    blob_resource = Info.storage_blob_resource!(resource)

    with {:ok, extra_blob_attrs} <- normalize_upload(service_mod.upload(key, variant_data, ctx)) do
      blob_attrs =
        %{
          key: key,
          filename: variant_filename,
          content_type: variant_content_type,
          byte_size: byte_size,
          checksum: checksum,
          service_name: service_mod,
          service_opts: persistable_service_opts(service_mod, service_opts),
          metadata: extra_metadata,
          variant_of_blob_id: source_blob.id,
          variant_name: to_string(variant_name),
          variant_digest: digest
        }
        |> Map.merge(extra_blob_attrs)

      Ash.create(blob_resource, blob_attrs, action: :create_variant)
    end
  end

  defp normalize_upload(:ok), do: {:ok, %{}}
  defp normalize_upload({:ok, attrs}) when is_map(attrs), do: {:ok, attrs}
  defp normalize_upload({:error, _} = error), do: error

  defp resolve_service(resource, attachment_def) do
    case Info.service_for_attachment(resource, attachment_def) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :no_service_configured}
    end
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
end
