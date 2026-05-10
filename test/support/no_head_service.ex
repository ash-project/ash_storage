defmodule AshStorage.Test.NoHeadService do
  @moduledoc false
  @behaviour AshStorage.Service

  @doc """
  A test service that delegates to `AshStorage.Service.Test` but deliberately
  does NOT implement the optional `head/2` callback. Used to exercise the
  AttachBlob fallback path that warns and links without verification.
  """

  @impl true
  def upload(key, data, ctx), do: AshStorage.Service.Test.upload(key, data, ctx)

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
