defmodule AshStorage.Calculations.VariantUrl do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def strict_loads?, do: false

  @impl true
  def load(_query, opts, _context) do
    [{opts[:attachment_name], blob: :variants}]
  end

  @impl true
  def calculate(records, opts, context) do
    attachment_name = opts[:attachment_name]
    variant_name = opts[:variant_name]
    resource = opts[:resource]
    {:ok, target} = AshStorage.Pipeline.resolve(resource, attachment_name)
    variant_def = Enum.find(target.attachment.variants, &(&1.name == variant_name))
    scope = AshStorage.Pipeline.Scope.from_calculation(context)
    {:ok, {service_mod, ctx}} = AshStorage.Pipeline.Target.service_context(target, scope)

    {:ok,
     Enum.map(records, fn record ->
       case Map.get(record, attachment_name) do
         nil ->
           nil

         attachment ->
           source_blob = attachment.blob

           variant_blob =
             find_variant_blob(source_blob, variant_def) ||
               generate_variant(source_blob, variant_def, target, scope)

           if variant_blob do
             url_ctx =
               AshStorage.Service.Context.put_blob_metadata(ctx,
                 content_type: variant_blob.content_type,
                 filename: variant_blob.filename
               )

             service_mod.url(variant_blob.key, url_ctx)
           end
       end
     end)}
  end

  defp find_variant_blob(source_blob, variant_def) do
    digest = AshStorage.VariantDefinition.digest(variant_def)

    Enum.find(source_blob.variants, fn v ->
      v.variant_name == to_string(variant_def.name) && v.variant_digest == digest
    end)
  end

  defp generate_variant(source_blob, variant_def, target, scope) do
    case AshStorage.VariantGenerator.generate(source_blob, variant_def, target, scope) do
      {:ok, variant_blob} -> variant_blob
      {:error, _} -> nil
    end
  end
end
