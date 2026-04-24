defmodule AshStorage.Test.ExtraAttrsService do
  @moduledoc false
  @behaviour AshStorage.Service

  @doc """
  A test service wrapper that returns extra blob attributes from upload/3.
  Delegates storage to the Test service but returns `{:ok, map()}` with
  additional metadata to verify the extra_blob_attrs merge path.
  """

  @impl true
  def upload(key, data, ctx) do
    case AshStorage.Service.Test.upload(key, data, ctx) do
      :ok -> {:ok, %{metadata: %{"injected" => "from_service", "key" => key}}}
      error -> error
    end
  end

  @impl true
  def download(key, ctx), do: AshStorage.Service.Test.download(key, ctx)

  @impl true
  def delete(key, ctx), do: AshStorage.Service.Test.delete(key, ctx)

  @impl true
  def exists?(key, ctx), do: AshStorage.Service.Test.exists?(key, ctx)

  @impl true
  def url(key, ctx), do: AshStorage.Service.Test.url(key, ctx)

  @impl true
  def direct_upload(key, ctx), do: AshStorage.Service.Test.direct_upload(key, ctx)
end
