defmodule AshStorage.VariantGenerator do
  @moduledoc false

  alias AshStorage.BlobIO
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
    source_bctx =
      BlobIO.BlobContext.new(
        resource: resource,
        attachment: attachment_def,
        blob: source_blob,
        operation: :variant,
        variant: variant_name
      )

    with {:ok, source_data} <- BlobIO.read(source_blob, source_bctx),
         {:ok, transform_result, variant_data} <- run_transform(module, opts, source_data) do
      upload_and_create_variant(
        source_blob,
        variant_name,
        digest,
        transform_result,
        variant_data,
        resource,
        attachment_def
      )
    end
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
         attachment_def
       ) do
    variant_content_type =
      Map.get(transform_metadata, :content_type, source_blob.content_type)

    variant_filename =
      Map.get(transform_metadata, :filename, "#{variant_name}_#{source_blob.filename}")

    extra_metadata =
      transform_metadata
      |> Map.drop([:content_type, :filename])

    bctx =
      BlobIO.BlobContext.new(
        resource: resource,
        attachment: attachment_def,
        blob: source_blob,
        operation: :variant,
        variant: variant_name
      )

    BlobIO.write(variant_data, bctx,
      action: :create_variant,
      key: AshStorage.resolve_variant_key(source_blob.key),
      filename: variant_filename,
      content_type: variant_content_type,
      metadata: extra_metadata,
      blob_attrs: %{
        variant_of_blob_id: source_blob.id,
        variant_name: to_string(variant_name),
        variant_digest: digest
      }
    )
  end
end
