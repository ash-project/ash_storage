defmodule AshStorage.Pipeline.Target do
  @moduledoc false
  # A resolved attachment: the host resource, its attachment definition, the
  # service configured for it and the resources that reference it. Built by
  # `AshStorage.Pipeline.resolve/2`.

  alias AshStorage.Pipeline.Scope
  alias AshStorage.Service.Context

  defstruct [:resource, :attachment, :service, :blob_resource, :attachment_resource, :owner]

  @type t :: %__MODULE__{
          resource: Ash.Resource.t(),
          attachment: AshStorage.AttachmentDefinition.t(),
          service: {module(), keyword()} | nil,
          blob_resource: Ash.Resource.t(),
          attachment_resource: Ash.Resource.t(),
          owner: AshStorage.Pipeline.Owner.t()
        }

  @doc "The configured service and a context for it, for uploads under this attachment."
  @spec service_context(t(), Scope.t()) ::
          {:ok, {module(), Context.t()}} | {:error, :no_service_configured}
  def service_context(%__MODULE__{service: nil}, _scope), do: {:error, :no_service_configured}

  def service_context(%__MODULE__{service: {service_mod, service_opts}} = target, scope) do
    {:ok, {service_mod, context(service_opts, scope, target)}}
  end

  @doc """
  A context for the service that stored `blob`, built from the options
  persisted on it. When `target` is given and its service is the blob's, the
  persisted options are merged over the live ones, so that options that are
  not persisted (credentials, for example) are still there.
  """
  @spec blob_context(struct(), Scope.t(), t() | nil) :: Context.t()
  def blob_context(blob, scope, target \\ nil) do
    persisted = persisted_service_opts(blob)

    service_opts =
      case target do
        %__MODULE__{service: {service_mod, live_opts}} when service_mod == blob.service_name ->
          Keyword.merge(live_opts, persisted)

        _ ->
          persisted
      end

    context(service_opts, scope, target)
  end

  @doc "The service options persisted on `blob`, cast back to a keyword list."
  @spec persisted_service_opts(struct()) :: keyword()
  def persisted_service_opts(blob) do
    service_mod = blob.service_name

    if Code.ensure_loaded?(service_mod) and
         function_exported?(service_mod, :service_opts_fields, 0) do
      fields = service_mod.service_opts_fields()

      case Ash.Type.cast_stored(Ash.Type.Keyword, blob.service_opts || %{}, fields: fields) do
        {:ok, opts} -> opts
        _ -> []
      end
    else
      []
    end
  end

  @doc "The part of `service_opts` that is stored on a new blob."
  @spec persistable_service_opts(module(), keyword()) :: map()
  def persistable_service_opts(service_mod, service_opts) do
    if Code.ensure_loaded?(service_mod) and
         function_exported?(service_mod, :service_opts_fields, 0) do
      field_names = Keyword.keys(service_mod.service_opts_fields())

      service_opts
      |> Keyword.take(field_names)
      |> Map.new()
    else
      %{}
    end
  end

  defp context(service_opts, scope, target) do
    Context.new(service_opts,
      resource: target && target.resource,
      attachment: target && target.attachment,
      actor: scope.actor,
      tenant: scope.tenant
    )
  end
end
