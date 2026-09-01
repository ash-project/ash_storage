defmodule AshStorage.BlobIO.BlobContext do
  @moduledoc """
  Logical operation context for blob IO.

  `AshStorage.Service.Context` remains the context passed to raw storage
  services. This struct is the outer context for logical attachment operations
  that may involve records, attachment rows, variants, analyzers, or other
  state that does not belong on the service adapter boundary.

  BlobIO operation structs carry a `BlobContext` as `blob_context`; layers can
  inspect that context without requiring every phase to grow another set of
  fields.

  The `operation` field is an **atom** naming the logical call (e.g. `:read`,
  `:write`, `:rewrap`) — distinct from the per-phase `*.Operation` structs (see
  the terminology note on `AshStorage.Layer`).
  """

  alias AshStorage.Service

  defstruct [
    :resource,
    :attachment,
    :record,
    :attachment_row,
    :blob,
    :actor,
    :tenant,
    :operation,
    :name,
    :variant,
    :analyzer
  ]

  @typedoc "Logical operation context shared by BlobIO phases and layers."
  @type t :: %__MODULE__{
          resource: module() | nil,
          attachment: struct() | nil,
          record: struct() | nil,
          attachment_row: struct() | nil,
          blob: struct() | nil,
          actor: term(),
          tenant: term(),
          operation: atom() | nil,
          name: atom() | nil,
          variant: atom() | nil,
          analyzer: module() | nil
        }

  @doc "Build a BlobIO context from keyword options."
  def new(opts \\ []) when is_list(opts) do
    # All fields are straight passthrough except `name`, which defaults to the
    # attachment's name; everything else falls back to the struct's nil defaults.
    opts = Keyword.put_new_lazy(opts, :name, fn -> attachment_name(opts[:attachment]) end)
    struct(__MODULE__, opts)
  end

  @doc "Build context from an Ash changeset and an attachment definition."
  def from_changeset(changeset, attachment, opts \\ []) do
    opts
    |> Keyword.put_new(:resource, changeset.resource)
    |> Keyword.put_new(:record, changeset.data)
    |> Keyword.put_new(:attachment, attachment)
    |> Keyword.put_new(:actor, changeset.context[:private][:actor])
    |> Keyword.put_new(:tenant, changeset.tenant)
    |> new()
  end

  @doc "Build context from operation options used by public APIs."
  def from_opts(resource, attachment, opts \\ []) do
    opts
    |> Keyword.put_new(:resource, resource)
    |> Keyword.put_new(:attachment, attachment)
    |> new()
  end

  @doc "Attach the current blob to an existing BlobContext."
  def put_blob(%__MODULE__{} = bctx, blob), do: %{bctx | blob: blob}

  @doc """
  Project a BlobIO context into the service context expected by service modules.
  """
  def to_service_context(%__MODULE__{} = bctx, service_opts \\ []) do
    service_opts = maybe_put_original_filename(service_opts, bctx.blob)

    Service.Context.new(service_opts,
      resource: bctx.resource,
      attachment: bctx.attachment,
      actor: bctx.actor,
      tenant: bctx.tenant
    )
  end

  defp maybe_put_original_filename(service_opts, %{filename: filename})
       when is_binary(filename) do
    Keyword.put(service_opts, :original_filename, filename)
  end

  defp maybe_put_original_filename(service_opts, _blob), do: service_opts

  defp attachment_name(%{name: name}), do: name
  defp attachment_name(_), do: nil
end
