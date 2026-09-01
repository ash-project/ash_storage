defmodule AshStorage.BlobIO.Writer do
  @moduledoc false
  # BlobIO write phase: run write layers, upload to the service, create the blob
  # row, then drain post-create finalizations registered via `Layer.finalize/3`.
  # Emitted layer metadata is persisted so reads can rebuild the chain. Internal —
  # `AshStorage.BlobIO.write/3` is the public entry.

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.Layers

  alias AshStorage.BlobIO.Operation.{
    BlobDraft,
    CreateParams,
    Finalization,
    PostCreate,
    ServiceState
  }

  alias AshStorage.BlobIO.Support
  alias AshStorage.Info

  defmodule Operation do
    @moduledoc """
    Phase-local state passed through write layers.

    The fields fall into three groups, so a layer author can see at a glance
    which are theirs:

      * **Layer-facing** — what a `write/2` callback reads and transforms:
        `data` (logical bytes; mutate via `Layer.data/1` + `Layer.put_data/2`),
        `draft` (blob row attributes a layer may adjust before creation),
        `layer_metadata` (append durable metadata via `Layer.put_metadata/3`),
        and `finalizations` (register post-create steps via `Layer.finalize/3`).
      * **Shared context (read-only for layers)** — `blob_context`, `call_opts`,
        and `blob` (nil during the write phase; populated only for the
        post-create `PostCreate` context).
      * **Framework-owned** — the writer's own plumbing, which layers should not
        touch: `service` (adapter binding), `create_params` (the `Ash.create`
        action + opts), and `layers` (the chain the runner iterates).
    """

    defstruct [
      :blob_context,
      :data,
      :draft,
      :service,
      :blob,
      create_params: %CreateParams{},
      layer_metadata: [],
      finalizations: [],
      layers: [],
      call_opts: []
    ]

    @typedoc "Mutable operation payload for logical blob writes."
    @type t :: %__MODULE__{
            blob_context: BlobContext.t(),
            data: binary(),
            draft: BlobDraft.t(),
            service: ServiceState.t(),
            blob: struct() | nil,
            create_params: CreateParams.t(),
            layer_metadata: [map()],
            finalizations: [Finalization.t()],
            layers: [AshStorage.Layer.spec()],
            call_opts: keyword()
          }
  end

  @doc """
  Write logical bytes through BlobIO and create a blob record.

  Service upload happens before `Ash.create/3`, preserving the existing
  behavior where adapter upload errors return before any blob row is created.
  """
  def write(input, %BlobContext{} = bctx, opts) when is_list(opts) do
    with {:ok, {service_mod, service_opts}} <- Support.resolve_service(bctx, opts) do
      operation =
        %Operation{
          blob_context: bctx,
          data: Support.input_to_binary(input),
          draft: BlobDraft.new(opts),
          create_params: %CreateParams{
            action: Keyword.get(opts, :action, :create),
            ash_opts: Keyword.get(opts, :ash_opts, [])
          },
          call_opts: opts,
          service: ServiceState.new(service_mod, service_opts),
          layers: Support.layers_for(bctx, opts)
        }
        |> Support.put_service_context()

      with {:ok, operation} <- Layers.run(operation, :write),
           operation = put_size_attrs(operation),
           operation = Support.put_service_context(operation),
           :ok <- Support.validate_key(operation.draft.key),
           {:ok, service_attrs} <-
             Support.normalize_upload(
               operation.service.mod.upload(
                 operation.draft.key,
                 operation.data,
                 operation.service.context
               )
             ) do
        blob_resource = Info.storage_blob_resource!(operation.blob_context.resource)

        blob_attrs =
          %{
            key: operation.draft.key,
            filename: operation.draft.filename,
            content_type: operation.draft.content_type,
            byte_size: operation.draft.byte_size,
            checksum: operation.draft.checksum,
            service_name: operation.service.mod,
            service_opts:
              Support.persistable_service_opts(operation.service.mod, operation.service.opts),
            metadata:
              Support.put_layer_metadata(operation.draft.metadata, operation.layer_metadata)
          }
          |> Map.merge(operation.draft.attrs)
          |> Map.merge(service_attrs)

        with {:ok, blob} <-
               Ash.create(
                 blob_resource,
                 blob_attrs,
                 Keyword.merge(operation.create_params.ash_opts,
                   action: operation.create_params.action
                 )
               ),
             operation = put_blob(operation, blob),
             :ok <- run_finalizations(operation) do
          {:ok, operation.blob}
        end
      end
    end
  end

  defp put_size_attrs(%Operation{data: data} = operation) when is_binary(data) do
    draft = %{
      operation.draft
      | checksum: :crypto.hash(:md5, data) |> Base.encode64(),
        byte_size: byte_size(data)
    }

    %{operation | draft: draft}
  end

  # Finalization is a first-class post-create step. Layers register a
  # typed `Finalization` closure during `write/2`; the writer (not a second
  # layer callback) builds the post-create context once and invokes each closure
  # in configured write order. The first error halts and is returned; the blob
  # row already exists, so finalizations carry an at-least-once / idempotent
  # contract (see Operation.Finalization + the Encryption guide).
  defp run_finalizations(%Operation{finalizations: finalizations} = operation) do
    context = %PostCreate{
      blob_context: operation.blob_context,
      blob: operation.blob,
      draft: operation.draft,
      service: operation.service,
      layer_metadata: operation.layer_metadata,
      call_opts: operation.call_opts
    }

    Enum.reduce_while(finalizations, :ok, fn %Finalization{run: run}, :ok ->
      case run.(context) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_blob(%Operation{} = operation, blob) do
    operation
    |> Map.put(:blob, blob)
    |> Map.put(:blob_context, BlobContext.put_blob(operation.blob_context, blob))
    |> Support.put_service_context()
  end
end
