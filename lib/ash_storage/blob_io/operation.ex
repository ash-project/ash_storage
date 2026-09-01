defmodule AshStorage.BlobIO.Operation do
  @moduledoc false
  # Namespace for the shared structs embedded in the per-phase `*.Operation`
  # payloads: ServiceState, BlobDraft, CreateParams, PostCreate, Finalization.
  # Not itself a phase operation (those are Reader.Operation, Writer.Operation,
  # etc.); the embedded structs that layers see carry their own docs.

  defmodule ServiceState do
    @moduledoc """
    Storage service state carried by BlobIO phase operations.

    `opts` are the mutable service options visible to layers. `context` is
    rebuilt from those options when crossing the storage adapter boundary.
    """

    alias AshStorage.Service

    defstruct [:mod, :context, opts: []]

    @type t :: %__MODULE__{
            mod: module() | nil,
            context: Service.Context.t() | nil,
            opts: keyword()
          }

    @doc "Build service state from a resolved storage service pair."
    def new(mod, opts) when is_list(opts), do: %__MODULE__{mod: mod, opts: opts}
  end

  defmodule BlobDraft do
    @moduledoc """
    Draft blob-row attributes carried by write and direct-upload operations.

    Layers may adjust these fields before BlobIO persists the blob record.
    """

    defstruct [
      :key,
      :filename,
      :content_type,
      :checksum,
      :byte_size,
      attrs: %{},
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            filename: String.t(),
            content_type: String.t(),
            checksum: String.t() | nil,
            byte_size: non_neg_integer() | nil,
            attrs: map(),
            metadata: map()
          }

    @doc "Build draft blob attributes from public BlobIO call options."
    def new(opts) when is_list(opts) do
      %__MODULE__{
        key: Keyword.get_lazy(opts, :key, &AshStorage.generate_key/0),
        filename: Keyword.fetch!(opts, :filename),
        content_type: Keyword.get(opts, :content_type, "application/octet-stream"),
        checksum: Keyword.get(opts, :checksum),
        byte_size: Keyword.get(opts, :byte_size),
        attrs: Keyword.get(opts, :blob_attrs, %{}),
        metadata: Keyword.get(opts, :metadata, %{})
      }
    end
  end

  defmodule CreateParams do
    @moduledoc """
    Framework-owned `Ash.create` binding carried on a write operation (`action`
    plus `ash_opts`).

    Part of the write operation's shape, but **not** layer-facing — the writer
    owns it to persist the blob row; layers should not touch it.
    """

    defstruct action: :create, ash_opts: []

    @type t :: %__MODULE__{
            action: atom(),
            ash_opts: keyword()
          }
  end

  defmodule PostCreate do
    @moduledoc """
    Framework-built context handed to each write finalization after blob creation.

    The writer assembles this once, after the service upload and `Ash.create`
    succeed, and passes it to every registered `Finalization`. It exposes the
    now-created `blob` plus the surrounding write state a finalization may need;
    finalizations capture their own per-layer state in their closure.
    """

    alias AshStorage.BlobIO.BlobContext

    defstruct [:blob_context, :blob, :draft, :service, layer_metadata: [], call_opts: []]

    @type t :: %__MODULE__{
            blob_context: BlobContext.t(),
            blob: struct(),
            draft: BlobDraft.t(),
            service: ServiceState.t(),
            layer_metadata: [map()],
            call_opts: keyword()
          }
  end

  defmodule Finalization do
    @moduledoc """
    A first-class post-create write step registered by a layer during `write/2`.

    Rather than stashing opaque state on the operation and re-deriving it in a
    second callback, a layer registers an explicitly-typed `run` closure (via
    `AshStorage.Layer.finalize/3`). After the blob row exists, the writer
    invokes each `run` with a `PostCreate` context, in configured write order.

    The closure is runtime-only — it may capture sensitive material (e.g. a DEK
    handoff) and is never persisted in blob metadata. Its contract is
    at-least-once from the layer's perspective: it runs after the object and row
    are committed, so a failure here leaves a persisted blob whose finalization
    did not complete. Closures should therefore be idempotent and the application
    owns any compensating cleanup (see the Encryption guide).
    """

    @enforce_keys [:layer_metadata_key, :run]
    defstruct [:layer_metadata_key, :run]

    @type t :: %__MODULE__{
            layer_metadata_key: String.t(),
            run: (PostCreate.t() -> :ok | {:error, term()})
          }
  end
end
