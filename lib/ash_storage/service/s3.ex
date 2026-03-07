defmodule AshStorage.Service.S3 do
  @moduledoc """
  A storage service that stores files in Amazon S3 or S3-compatible services.

  This module requires the optional `:ex_aws_s3` dependency.

  ## Configuration

      config :ash_storage, :services,
        s3: {AshStorage.Service.S3, bucket: "my-bucket", region: "us-east-1"}
  """

  @behaviour AshStorage.Service

  @impl true
  def upload(_key, _io, _opts) do
    {:error, :not_implemented}
  end

  @impl true
  def download(_key, _opts) do
    {:error, :not_implemented}
  end

  @impl true
  def delete(_key) do
    {:error, :not_implemented}
  end

  @impl true
  def exists?(_key) do
    false
  end

  @impl true
  def url(_key, _opts) do
    raise "S3 service not yet implemented"
  end

  @impl true
  def direct_upload_url(_key, _opts) do
    {:error, :not_implemented}
  end
end
