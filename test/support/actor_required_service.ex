defmodule AshStorage.Test.ActorRequiredService do
  @moduledoc false
  @behaviour AshStorage.Service

  @impl true
  def upload(key, data, ctx) do
    if ctx.actor == :authorized do
      AshStorage.Service.Test.upload(key, data, ctx)
    else
      {:error, :missing_actor}
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
