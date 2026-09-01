defmodule AshStorage.Layer do
  @moduledoc """
  Behaviour for modules that participate in the layer chain.

  Layers are part of the logical BlobIO path. They may transform bytes, affect
  serving policy, or reject/adjust direct-upload preparation. A layer may be
  configured on the storage DSL, on an attachment, or passed explicitly to raw
  handoff calls with `:layers`. Layers that need the created blob row register a
  post-create finalization during `write/2` with `finalize/3`.

  Layer stacks wrap and unwrap like an onion: writes call `write/2` in
  configured order, and reads call `read/2` in reverse persisted order.
  Registered finalizations run after blob creation in configured write order.

  Durable blob metadata stores layer metadata keys and layer metadata.
  Encrypted key material can be layer metadata, but runtime modules, key-manager
  modules, vault modules, plaintext keys, and raw secrets belong in runtime
  configuration. Runtime configuration maps persisted keys back to layer modules.

  The generic layer model is documented in the `Layers` guide. The
  bundled encryption layer and key-manager behavior are documented separately
  in the `Encryption` guide.

  ## Terminology: `operation` vs `Operation`

  Three related things share the word; they are distinct:

    * `BlobContext.operation` — an **atom** naming the logical call (e.g.
      `:read`, `:write`, `:rewrap`, `:serving`, `:direct_upload`).
    * `Reader.Operation` / `Writer.Operation` / `Serving.Operation` /
      `DirectUploads.Operation` — the per-phase **structs** threaded through a
      single phase's layers; one of these is what a `write/2` or `read/2`
      callback receives.
    * The shared embedded structs the phase structs build from —
      `AshStorage.BlobIO.Operation.ServiceState`, `BlobDraft`, `PostCreate`, and
      friends — building blocks, not phase operations themselves.
  """

  alias AshStorage.BlobIO.DirectUploads
  alias AshStorage.BlobIO.Operation.Finalization
  alias AshStorage.BlobIO.Reader
  alias AshStorage.BlobIO.Serving
  alias AshStorage.BlobIO.Writer

  @type spec :: module() | {module(), keyword()}
  @type result(struct) :: {:ok, struct} | {:error, term()}

  @doc """
  Return this layer's *default* durable metadata key.

  The framework resolves a configured layer's effective key by preferring a
  configured `metadata_key` (surfaced as the `:layer_metadata_key` option) and
  falling back to this default. Implementations therefore usually return a plain
  string; `opts` is available for layers that derive a default from
  configuration. A configured `metadata_key` is always honored without the
  implementation handling the override itself.
  """
  @callback default_metadata_key(keyword()) :: String.t()

  @doc """
  Transform logical write bytes or metadata before service upload.

  A layer that needs the created blob row registers a post-create
  `AshStorage.BlobIO.Operation.Finalization` here via `finalize/3` rather than
  observing a separate callback.
  """
  @callback write(Writer.Operation.t(), keyword()) :: result(Writer.Operation.t())

  @doc "Transform raw stored bytes back into logical bytes after service download."
  @callback read(Reader.Operation.t(), keyword()) :: result(Reader.Operation.t())

  @doc "Adjust or select the serving strategy for URL generation."
  @callback serving(Serving.Operation.t(), keyword()) :: result(Serving.Operation.t())

  @doc """
  Adjust pending blob attributes or service options before a direct upload, or
  reject the operation.

  A direct upload streams bytes client → service, so the server is never in the
  byte path. This callback can adjust the pending blob (attributes, metadata,
  service options) and persist layer metadata, but it **cannot transform bytes**.
  A layer that must see the bytes — any byte-transforming layer, such as
  encryption — should reject preparation by returning `{:error, reason}` rather
  than letting raw bytes be stored under metadata that claims a transform. See the
  "Direct uploads" section of the `Layers` guide.
  """
  @callback direct_upload(DirectUploads.Operation.t(), keyword()) ::
              result(DirectUploads.Operation.t())

  @optional_callbacks write: 2, read: 2, serving: 2, direct_upload: 2

  @doc """
  Resolve the effective durable layer metadata key for a configured layer spec.

  Prefers a configured `:layer_metadata_key` option (set from the `metadata_key`
  DSL field) and otherwise falls back to the layer's `c:default_metadata_key/1`.
  """
  def layer_metadata_key(module) when is_atom(module), do: layer_metadata_key({module, []})

  def layer_metadata_key({module, opts}) when is_atom(module) and is_list(opts) do
    case Keyword.fetch(opts, :layer_metadata_key) do
      {:ok, layer_metadata_key} -> to_string(layer_metadata_key)
      :error -> to_string(module.default_metadata_key(opts))
    end
  end

  @doc """
  Read the logical bytes a write or read operation currently carries.

  This is the layer-facing byte view: on write it is the bytes produced by
  earlier layers; on read it is the bytes produced by later layers unwrapping.
  """
  def data(%{data: data}), do: data

  @doc "Replace the logical bytes on a write or read operation."
  def put_data(%{data: _} = operation, data) when is_binary(data) do
    %{operation | data: data}
  end

  @doc "Append durable layer metadata while preparing a blob write."
  def put_metadata(context, layer_metadata_key, metadata)

  def put_metadata(%Writer.Operation{} = write, layer_metadata_key, metadata)
      when is_map(metadata) do
    put_layer_metadata(write, layer_metadata_key, metadata)
  end

  def put_metadata(%DirectUploads.Operation{} = direct_upload, layer_metadata_key, metadata)
      when is_map(metadata) do
    put_layer_metadata(direct_upload, layer_metadata_key, metadata)
  end

  defp put_layer_metadata(context, layer_metadata_key, metadata) do
    entry = %{
      "layer_metadata_key" => to_string(layer_metadata_key),
      "metadata" => metadata
    }

    %{context | layer_metadata: List.insert_at(context.layer_metadata, -1, entry)}
  end

  @doc """
  Register a first-class post-create finalization step while preparing a write.

  `run` is a one-arity closure invoked with an
  `AshStorage.BlobIO.Operation.PostCreate` context after the blob row exists, in
  configured write order. It runs after the object and row are committed, so it
  must be idempotent; the application owns any compensating cleanup if it fails.
  The closure is runtime-only and never persisted in blob metadata.
  """
  def finalize(%Writer.Operation{} = write, layer_metadata_key, run) when is_function(run, 1) do
    entry = %Finalization{layer_metadata_key: to_string(layer_metadata_key), run: run}

    %{write | finalizations: List.insert_at(write.finalizations, -1, entry)}
  end

  @doc "Fetch persisted metadata entries for a layer metadata key."
  def metadata(%{layer_metadata: entries}, layer_metadata_key) do
    layer_metadata_key = to_string(layer_metadata_key)

    Enum.filter(entries || [], fn
      %{"layer_metadata_key" => ^layer_metadata_key} -> true
      _entry -> false
    end)
  end
end
