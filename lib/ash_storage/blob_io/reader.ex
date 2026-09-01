defmodule AshStorage.BlobIO.Reader do
  @moduledoc false
  # BlobIO read phase: download raw bytes from the service, then run read layers
  # (matched from the blob's persisted layer metadata, reverse order) to recover
  # logical bytes. Internal — `AshStorage.BlobIO.read/3` is the public entry.

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.Layers
  alias AshStorage.BlobIO.Operation.ServiceState
  alias AshStorage.BlobIO.Support

  defmodule Operation do
    @moduledoc """
    Phase-local state passed through read layers.

    `data` starts as raw service bytes and should end as logical bytes. Read
    layers run in reverse write order.
    """

    defstruct [
      :blob_context,
      :blob,
      :key,
      :data,
      :service,
      layer_metadata: [],
      layers: [],
      call_opts: []
    ]

    @typedoc "Mutable operation payload for logical blob reads."
    @type t :: %__MODULE__{
            blob_context: BlobContext.t(),
            blob: struct() | nil,
            key: String.t(),
            data: binary() | nil,
            service: ServiceState.t(),
            layer_metadata: [map()],
            layers: [AshStorage.Layer.spec()],
            call_opts: keyword()
          }
  end

  @doc """
  Read logical bytes for a persisted blob.

  Service options and layer metadata come from the blob record. Runtime layer
  modules are matched back to persisted layer metadata keys before any bytes are
  returned.
  """
  def read(blob, %BlobContext{} = bctx, opts) when is_list(opts) do
    blob = Ash.load!(blob, :parsed_service_opts)
    service_opts = blob.parsed_service_opts || []
    bctx = BlobContext.put_blob(bctx, blob)
    layer_metadata = Support.layer_metadata_from_blob(blob)

    with {:ok, layers} <- Support.layers_for_read(bctx, opts, layer_metadata) do
      operation =
        %Operation{
          blob_context: bctx,
          blob: blob,
          key: blob.key,
          call_opts: opts,
          service: ServiceState.new(blob.service_name, service_opts),
          layer_metadata: layer_metadata,
          layers: layers
        }
        |> Support.put_service_context()

      with {:ok, data} <-
             operation.service.mod.download(operation.key, operation.service.context),
           {:ok, operation} <- Layers.run(%{operation | data: data}, :read) do
        {:ok, operation.data}
      end
    end
  end

  @doc """
  Read logical bytes directly from a service/key pair.

  This path is used by proxy serving, where there may not be a blob record or
  persisted layer metadata available.
  """
  def read_key(key, {service_mod, service_opts}, %BlobContext{} = bctx, opts)
      when is_binary(key) and is_list(service_opts) and is_list(opts) do
    operation =
      %Operation{
        blob_context: bctx,
        key: key,
        call_opts: opts,
        service: ServiceState.new(service_mod, service_opts),
        layers: Support.layers_for(bctx, opts)
      }
      |> Support.put_service_context()

    with {:ok, data} <- operation.service.mod.download(operation.key, operation.service.context),
         {:ok, operation} <- Layers.run(%{operation | data: data}, :read) do
      {:ok, operation.data}
    end
  end
end
