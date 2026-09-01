defmodule AshStorage.BlobIO.DirectUploads do
  @moduledoc false
  # BlobIO direct-upload preparation phase: create a pending blob row and ask the
  # service for client-side upload instructions, after running direct-upload
  # layers. Internal.

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.Layers
  alias AshStorage.BlobIO.Operation.{BlobDraft, ServiceState}
  alias AshStorage.BlobIO.Support
  alias AshStorage.Info

  defmodule Operation do
    @moduledoc """
    Phase-local state passed through direct-upload layers.

    The operation contains the future blob attributes plus the service context
    that will be used to request upload instructions from the adapter. Layers run
    their `direct_upload/2` callback over this struct — not `write/2` — because the
    bytes never pass through the server on a direct upload, so a byte-transforming
    layer adjusts/persists metadata or rejects here rather than transforming. See
    the "Direct uploads" section of the `Layers` guide.
    """

    defstruct [
      :blob_context,
      :draft,
      :service,
      ash_opts: [],
      layer_metadata: [],
      layers: [],
      call_opts: []
    ]

    @typedoc "Mutable operation payload for direct-upload preparation."
    @type t :: %__MODULE__{
            blob_context: BlobContext.t(),
            draft: BlobDraft.t(),
            service: ServiceState.t(),
            ash_opts: keyword(),
            layer_metadata: [map()],
            layers: [AshStorage.Layer.spec()],
            call_opts: keyword()
          }
  end

  @doc """
  Create a pending blob and return service-specific direct-upload information.

  Layer metadata is stored on the pending blob exactly as it is for normal
  writes, allowing later reads or completion flows to understand the BlobIO
  chain that shaped the upload.
  """
  def prepare(%BlobContext{} = bctx, opts) when is_list(opts) do
    with {:ok, {service_mod, service_opts}} <- Support.resolve_service(bctx, opts) do
      operation =
        %Operation{
          blob_context: bctx,
          draft: %BlobDraft{
            key: Keyword.get_lazy(opts, :key, &AshStorage.generate_key/0),
            filename: Keyword.fetch!(opts, :filename),
            content_type: Keyword.get(opts, :content_type, "application/octet-stream"),
            byte_size: Keyword.get(opts, :byte_size, 0),
            checksum: Keyword.get(opts, :checksum, ""),
            metadata: Keyword.get(opts, :metadata, %{})
          },
          ash_opts: Keyword.get(opts, :ash_opts, []),
          call_opts: opts,
          service: ServiceState.new(service_mod, service_opts),
          layers: Support.layers_for(bctx, opts)
        }
        |> Support.put_service_context()

      with {:ok, operation} <- Layers.run(operation, :direct_upload),
           operation = Support.put_service_context(operation),
           :ok <- Support.validate_key(operation.draft.key),
           blob_resource = Info.storage_blob_resource!(operation.blob_context.resource),
           {:ok, blob} <-
             Ash.create(
               blob_resource,
               %{
                 key: operation.draft.key,
                 filename: operation.draft.filename,
                 content_type: operation.draft.content_type,
                 byte_size: operation.draft.byte_size,
                 checksum: operation.draft.checksum,
                 service_name: operation.service.mod,
                 service_opts:
                   Support.persistable_service_opts(
                     operation.service.mod,
                     operation.service.opts
                   ),
                 metadata:
                   Support.put_layer_metadata(operation.draft.metadata, operation.layer_metadata)
               },
               Keyword.merge(operation.ash_opts, action: :create)
             ),
           {:ok, upload_info} <-
             operation.service.mod.direct_upload(operation.draft.key, operation.service.context) do
        {:ok, Map.put(upload_info, :blob, blob)}
      end
    end
  end
end
