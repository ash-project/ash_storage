defmodule AshStorage.Calculations.Url do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def strict_loads?, do: false

  # sobelow_skip ["DOS.BinToAtom"]
  @impl true
  def load(_query, opts, _context) do
    case opts[:parent_resources] do
      [] ->
        [:name, :record_type, :blob]

      parents ->
        parent_fields = Enum.map(parents, fn {name, _} -> :"#{name}_id" end)
        [:name, :blob | parent_fields]
    end
  end

  # sobelow_skip ["DOS.BinToAtom"]
  @impl true
  def calculate(records, opts, context) do
    parent_resources = opts[:parent_resources]

    {:ok,
     Enum.map(records, fn attachment ->
       with {:ok, resource} <- resolve_parent_resource(attachment, parent_resources),
            attachment_name = String.to_existing_atom(attachment.name),
            {:ok, attachment_def} <- AshStorage.Info.attachment(resource, attachment_name),
            {:ok, {service_mod, service_opts}} <-
              AshStorage.Info.service_for_attachment(resource, attachment_def) do
         ctx =
           AshStorage.Service.Context.new(service_opts,
             resource: resource,
             attachment: attachment_def,
             actor: Map.get(context, :actor),
             tenant: Map.get(context, :tenant)
           )

         service_mod.url(attachment.blob.key, ctx)
       else
         _ -> nil
       end
     end)}
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp resolve_parent_resource(attachment, []) do
    {:ok, String.to_existing_atom(attachment.record_type)}
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp resolve_parent_resource(attachment, parent_resources) do
    case Enum.find_value(parent_resources, fn {name, resource} ->
           if Map.get(attachment, :"#{name}_id") != nil, do: resource
         end) do
      nil -> :error
      resource -> {:ok, resource}
    end
  end
end
