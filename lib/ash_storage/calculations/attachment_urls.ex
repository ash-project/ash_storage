defmodule AshStorage.Calculations.AttachmentUrls do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def strict_loads?, do: false

  @impl true
  def load(_query, opts, _context) do
    [{opts[:attachment_name], :blob}]
  end

  @impl true
  def calculate(records, opts, context) do
    attachment_name = opts[:attachment_name]
    resource = opts[:resource]
    {:ok, attachment_def} = AshStorage.Info.attachment(resource, attachment_name)

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
           Enum.map(attachments, fn att ->
             url_ctx = %{
               ctx
               | service_opts:
                   Keyword.put(ctx.service_opts, :original_filename, att.blob.filename)
             }

             service_mod.url(att.blob.key, url_ctx)
           end)

         _other ->
           []
       end
     end)}
  end
end
