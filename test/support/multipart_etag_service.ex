defmodule AshStorage.Test.MultipartEtagService do
  @moduledoc false
  @behaviour AshStorage.Service

  @doc """
  A test service that simulates an S3 multipart blob: `head/2` returns an
  ETag with the `-N` suffix and no `content_md5`. AttachBlob's tier-3 logic
  is exercised against this — verification falls back to fail-loud (when
  `blob.checksum` is set) or warn-and-pass (when empty).
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

  @impl true
  def head(_key, _ctx) do
    {:ok, %{etag: "abc-2", content_md5: nil, byte_size: nil}}
  end
end
