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

    bctx =
      AshStorage.BlobIO.BlobContext.new(
        resource: resource,
        attachment: attachment_def,
        actor: Map.get(context, :actor),
        tenant: Map.get(context, :tenant),
        operation: :serve
      )

    {:ok,
     Enum.map(records, fn record ->
       case Map.get(record, attachment_name) do
         nil ->
           []

         attachments when is_list(attachments) ->
           Enum.map(attachments, fn att -> AshStorage.BlobIO.url(att.blob, bctx) end)

         _other ->
           []
       end
     end)}
  end
end
