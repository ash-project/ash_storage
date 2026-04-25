defmodule AshStorage.Calculations.VariantUrls do
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
    {:ok, attachment_def} = AshStorage.Info.attachment(resource, attachment_name)
    variant_def = Enum.find(attachment_def.variants, &(&1.name == variant_name))

    {:ok, {service_mod, service_opts}} =
      AshStorage.Info.service_for_attachment(resource, attachment_def)

    ctx =
      AshStorage.Service.Context.new(service_opts,
        resource: resource,
        attachment: attachment_def,
        actor: Map.get(context, :actor),
        tenant: Map.get(context, :tenant)
      )

    {:ok,
     Enum.map(records, fn record ->
       case Map.get(record, attachment_name) do
         nil ->
           []

         attachments when is_list(attachments) ->
           Enum.map(attachments, fn attachment ->
             source_blob = attachment.blob

             variant_blob =
               find_variant_blob(source_blob, variant_def) ||
                 generate_variant(source_blob, variant_def, resource, attachment_def)

             if variant_blob do
               service_mod.url(variant_blob.key, ctx)
             end
           end)

         _single ->
           []
       end
     end)}
  end

  defp find_variant_blob(source_blob, variant_def) do
    digest = AshStorage.VariantDefinition.digest(variant_def)

    Enum.find(source_blob.variants, fn v ->
      v.variant_name == to_string(variant_def.name) && v.variant_digest == digest
    end)
  end

  defp generate_variant(source_blob, variant_def, resource, attachment_def) do
    case AshStorage.VariantGenerator.generate(source_blob, variant_def, resource, attachment_def) do
      {:ok, variant_blob} -> variant_blob
      {:error, _} -> nil
    end
  end
end
