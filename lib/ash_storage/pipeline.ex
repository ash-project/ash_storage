defmodule AshStorage.Pipeline do
  @moduledoc false
  # The steps of attaching, replacing, detaching and purging a file, shared by
  # every way of doing so. Each step takes an explicit `Pipeline.Scope`.

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Pipeline.{Owner, Scope, Target}

  @doc "Resolves an attachment of `resource` by name."
  @spec resolve(Ash.Resource.t(), atom()) ::
          {:ok, Target.t()} | {:error, {:unknown_attachment, atom()}}
  def resolve(resource, attachment_name) do
    case Info.attachment(resource, attachment_name) do
      {:ok, attachment} ->
        service =
          case Info.service_for_attachment(resource, attachment) do
            {:ok, service} -> service
            :error -> nil
          end

        attachment_resource = Info.storage_attachment_resource!(resource)

        {:ok,
         %Target{
           resource: resource,
           attachment: attachment,
           service: service,
           blob_resource: Info.storage_blob_resource!(resource),
           attachment_resource: attachment_resource,
           owner: Owner.new(resource, attachment_resource)
         }}

      :error ->
        {:error, {:unknown_attachment, attachment_name}}
    end
  end

  @doc """
  The attachment rows of `record` under the target's attachment, with their
  blobs loaded. `filters` narrows them further, for example `blob_id: id`.
  """
  @spec attachments(struct(), Target.t(), Scope.t(), keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def attachments(record, %Target{} = target, %Scope{} = scope, filters \\ []) do
    filter = Owner.keys(target, record) ++ filters

    target.attachment_resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.load(:blob)
    |> Ash.read(Scope.to_opts(scope))
  end

  @doc "Creates the attachment row that links `blob` to `record`."
  @spec insert_attachment(struct(), struct(), Target.t(), Scope.t()) ::
          {:ok, struct()} | {:error, term()}
  def insert_attachment(record, blob, %Target{} = target, %Scope{} = scope) do
    params = Map.new(Owner.keys(target, record) ++ [blob_id: blob.id])

    Ash.create(target.attachment_resource, params, Scope.to_opts(scope, action: :create))
  end
end
