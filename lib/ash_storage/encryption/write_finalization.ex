defmodule AshStorage.Encryption.WriteFinalization do
  @moduledoc """
  Operation payload for post-write encryption key-manager finalization.

  `wrap_dek/3` runs before the blob row exists. Key managers that need the
  created blob can return an opaque handoff from `wrap_dek/3`; the encryption
  layer passes that handoff back in this struct after service upload and blob
  creation.

  The framework-built post-create context — the created `blob`, its
  `blob_context`, the write `draft`, resolved `service`, `layer_metadata`, and
  `call_opts` — is carried verbatim in `context`. This struct adds only the
  encryption layer's own per-write state: its `layer_metadata_key`, the
  persisted envelope `metadata`, and the runtime-only `handoff`.

  The handoff is runtime-only and may contain sensitive material. It is not
  persisted in blob metadata.
  """

  alias AshStorage.BlobIO.Operation.PostCreate

  defstruct [:context, :layer_metadata_key, :metadata, :handoff]

  @type t :: %__MODULE__{
          context: PostCreate.t(),
          layer_metadata_key: String.t(),
          metadata: map(),
          handoff: term()
        }
end
