defmodule AshStorage.BlobResource.Calculations.ParsedServiceOpts do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context) do
    [:service_name, :service_opts]
  end

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, &AshStorage.Pipeline.Target.persisted_service_opts/1)
  end
end
