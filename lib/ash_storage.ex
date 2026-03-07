defmodule AshStorage do
  @moduledoc """
  An Ash extension for file storage, attachments, and variants.

  AshStorage provides a consistent interface for uploading, storing, and serving
  files across multiple storage backends (local disk, S3, GCS, Azure). It includes
  support for file analysis, image variants, previews, and direct uploads.
  """

  @doc """
  Generate a unique key for storing a file.

  Returns a 56-character lowercase hex string.
  """
  def generate_key do
    Base.encode16(:crypto.strong_rand_bytes(28), case: :lower)
  end
end
