defmodule AshStorage.Test.ContextCapturingService do
  @moduledoc false
  @behaviour AshStorage.Service

  @doc """
  A test service wrapper that records the `Context` it was called with on
  each `upload/3`, keyed by `key`, in the calling process's dictionary.
  Delegates everything to `AshStorage.Service.Test`. Used to verify what a
  real service would see for `:content_type` / `:filename`, for upload
  paths (like eager variant generation) that run synchronously in the
  calling process.
  """

  @impl true
  def upload(key, data, ctx) do
    Process.put({__MODULE__, key}, ctx)
    AshStorage.Service.Test.upload(key, data, ctx)
  end

  @impl true
  def download(key, ctx), do: AshStorage.Service.Test.download(key, ctx)

  @impl true
  def delete(key, ctx), do: AshStorage.Service.Test.delete(key, ctx)

  @impl true
  def exists?(key, ctx), do: AshStorage.Service.Test.exists?(key, ctx)

  @impl true
  def url(key, ctx), do: AshStorage.Service.Test.url(key, ctx)

  def captured_context(key), do: Process.get({__MODULE__, key})
end
