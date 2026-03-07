defmodule AshStorage.Blob do
  @moduledoc """
  An Ash resource representing a file with its metadata.

  Blobs track files stored in storage services. Each blob has a unique key
  used to locate the file in storage, along with metadata about the file
  such as filename, content type, byte size, and checksum.

  ## Attributes

  - `key` - Unique identifier for locating the file in storage
  - `filename` - Original filename
  - `content_type` - MIME type of the file
  - `byte_size` - Size of the file in bytes
  - `checksum` - Base64-encoded MD5 digest of the file contents
  - `service_name` - Name of the storage service where the file is stored
  - `metadata` - JSON map containing analysis results and other metadata
  """

  use Ash.Resource,
    domain: nil,
    data_layer: :embedded

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
    end

    attribute :filename, :string do
      allow_nil? false
    end

    attribute :content_type, :string

    attribute :byte_size, :integer do
      allow_nil? false
    end

    attribute :checksum, :string do
      allow_nil? false
    end

    attribute :service_name, :atom do
      allow_nil? false
    end

    attribute :metadata, :map do
      default %{}
    end

    timestamps()
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:key, :filename, :content_type, :byte_size, :checksum, :service_name, :metadata]
    end

    update :update do
      primary? true
      accept [:metadata]
    end
  end

  @doc """
  Generate a unique key for storing a file.
  """
  def generate_key do
    Base.encode16(:crypto.strong_rand_bytes(28), case: :lower)
  end
end
