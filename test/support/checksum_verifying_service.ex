defmodule AshStorage.Test.ChecksumVerifyingService do
  @moduledoc false
  @behaviour AshStorage.Service

  @doc """
  A test service wrapper that mimics S3/Azure server-side `Content-MD5`
  verification. Delegates to `AshStorage.Service.Test`, but rejects when the
  context's `:expected_md5` doesn't match the body's actual MD5.
  """

  @impl true
  def upload(key, data, ctx) do
    case verify(ctx.expected_md5, data) do
      :ok -> AshStorage.Service.Test.upload(key, data, ctx)
      {:error, _} = error -> error
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

  defp verify(nil, _data), do: {:error, :missing_expected_md5}

  defp verify(expected, data) do
    actual = data |> IO.iodata_to_binary() |> :erlang.md5() |> Base.encode64()
    if actual == expected, do: :ok, else: {:error, :checksum_mismatch}
  end
end
