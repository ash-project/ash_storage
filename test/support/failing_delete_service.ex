defmodule AshStorage.Test.FailingDeleteService do
  @moduledoc false
  @behaviour AshStorage.Service

  @impl true
  def upload(key, data, ctx), do: AshStorage.Service.Test.upload(key, data, ctx)

  @impl true
  def download(key, ctx), do: AshStorage.Service.Test.download(key, ctx)

  @impl true
  def delete(_key, _ctx), do: {:error, :delete_failed}

  @impl true
  def exists?(key, ctx), do: AshStorage.Service.Test.exists?(key, ctx)

  @impl true
  def url(key, ctx), do: AshStorage.Service.Test.url(key, ctx)

  @impl true
  def direct_upload(key, ctx), do: AshStorage.Service.Test.direct_upload(key, ctx)
end
