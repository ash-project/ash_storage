defmodule AshStorage.Encryption.RewrapOperation do
  @moduledoc """
  Operation payload for encryption envelope rewraps.

  Rewrap operations change persisted wrapped-DEK metadata without changing blob
  bytes. Key managers can inspect this struct to choose recipient sets, KMS
  keys, labels, tenants, actors, or other policy inputs.
  """

  alias AshStorage.BlobIO.BlobContext

  defstruct [
    :blob_context,
    :blob,
    :layer_metadata_key,
    metadata: %{},
    layer_metadata: [],
    call_opts: []
  ]

  @type t :: %__MODULE__{
          blob_context: BlobContext.t(),
          blob: struct(),
          layer_metadata_key: String.t(),
          metadata: map(),
          layer_metadata: [map()],
          call_opts: keyword()
        }
end
