defmodule AshStorage.Encryption.KeyManager do
  @moduledoc """
  Behaviour for encryption key managers.

  `AshStorage.Layer.Encryption` owns byte encryption and decryption. Key
  managers own only the data encryption key (DEK) lifecycle: wrapping a newly
  generated DEK into durable metadata on write, and unwrapping that metadata
  back into a DEK on read.

  Wrapped DEK metadata is persisted on the blob as layer metadata. It may be a
  self-contained wrapped DEK or a descriptor for an external envelope, but it
  must not contain plaintext keys or raw secret material. Vault modules, KMS
  clients, tenant policy, and credentials remain runtime configuration.

  Implement `rewrap_dek/3` when the backing key system can change the wrapped
  DEK metadata without exposing the DEK to application code. If it is omitted,
  `AshStorage.Encryption.rewrap/3` falls back to `unwrap_dek/3` followed
  by `wrap_dek/3`.

  Key managers that need the created blob row can return
  `{:ok, wrapped_dek, handoff}` from `wrap_dek/3` and implement
  `finalize_wrapped_dek/3`. The handoff is runtime-only and is passed back after
  service upload and blob creation. The finalization operation carries it
  alongside the framework post-create context under `context` (`blob`,
  `blob_context`, write `draft`, resolved `service`, `layer_metadata`,
  `call_opts`); the layer's `layer_metadata_key` and persisted envelope
  `metadata` sit beside it.

  ## Contract notes for envelope and rewrap implementations

  - **The wrapped DEK is bound to its blob.** The encryption layer authenticates each blob's
    ciphertext with additional authenticated data derived from the blob's identity — its
    `key`, the layer metadata key, and the format id — *independently of the DEK envelope*. A
    `wrapped_dek` therefore cannot be moved or copied to another blob; only the blob it was
    written for decrypts. Rewrapping (below) changes only the envelope — never the ciphertext,
    IV, tag, or AAD.

  - **Rewrap fallback passes skeletal operations.** When `rewrap_dek/3` is not implemented,
    `AshStorage.Encryption.rewrap/3` falls back to `unwrap_dek/3` then `wrap_dek/3` with
    synthesized `Reader.Operation` / `Writer.Operation` structs that carry **no blob bytes and
    no resolved service context** (only the blob, key, and per-call options). A manager that
    reads bytes or service options during wrap/unwrap must implement `rewrap_dek/3` directly
    rather than relying on the fallback.

  - **A handoff requires `rewrap_dek/3`.** A `wrap_dek/3` that returns
    `{:ok, wrapped_dek, handoff}` depends on the post-create finalize phase, which the rewrap
    path does not have. Such a manager must implement `rewrap_dek/3` directly; a handoff
    returned during the rewrap fallback is rejected with
    `{:error, {:encryption_key_manager_rewrap_requires_finalize, module}}`.

  - **Exceptions are scrubbed.** An exception raised inside any callback is reduced to
    `{module, code-position}` before it surfaces — the message and arguments are dropped.
    Return anything a caller needs as a structured `{:error, reason}` value rather than
    relying on a raised exception's message reaching the caller.
  """

  alias AshStorage.BlobIO.Reader
  alias AshStorage.BlobIO.Writer
  alias AshStorage.Encryption.RewrapOperation
  alias AshStorage.Encryption.WriteFinalization

  @typedoc "Persistable wrapped-DEK metadata."
  @type wrapped_dek :: map()

  @typedoc """
  Runtime-only state passed from `wrap_dek/3` to `finalize_wrapped_dek/3`.
  """
  @type finalize_handoff :: term()

  @callback wrap_dek(binary(), Writer.Operation.t(), keyword()) ::
              {:ok, wrapped_dek()}
              | {:ok, wrapped_dek(), finalize_handoff()}
              | {:error, term()}

  @callback unwrap_dek(wrapped_dek(), Reader.Operation.t(), keyword()) ::
              {:ok, binary()} | {:error, term()}

  @callback rewrap_dek(wrapped_dek(), RewrapOperation.t(), keyword()) ::
              {:ok, wrapped_dek()} | {:error, term()}

  @callback finalize_wrapped_dek(wrapped_dek(), WriteFinalization.t(), keyword()) ::
              :ok | {:error, term()}

  @optional_callbacks rewrap_dek: 3, finalize_wrapped_dek: 3
end
