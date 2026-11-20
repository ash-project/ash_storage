defmodule AshStorage.Pipeline do
  @moduledoc false
  # The steps of attaching, replacing, detaching and purging a file, shared by
  # every way of doing so. Each step takes an explicit `Pipeline.Scope`.

  alias AshStorage.Info
  alias AshStorage.Pipeline.Target

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

        {:ok,
         %Target{
           resource: resource,
           attachment: attachment,
           service: service,
           blob_resource: Info.storage_blob_resource!(resource),
           attachment_resource: Info.storage_attachment_resource!(resource)
         }}

      :error ->
        {:error, {:unknown_attachment, attachment_name}}
    end
  end
end
