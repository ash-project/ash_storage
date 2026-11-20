defmodule AshStorage.Pipeline do
  @moduledoc false
  # The steps of attaching, replacing, detaching and purging a file, shared by
  # every way of doing so. Each step takes an explicit `Pipeline.Scope`.

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Pipeline.{Owner, Purge, Scope, Target}

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

  @doc """
  The attachments a detach or purge acts on: all of a `has_one`, and of a
  `has_many` the one holding `blob_id`, or all of them with `all?`.
  """
  @spec select([struct()], Target.t(), term(), boolean()) ::
          {:ok, [struct()]} | {:error, :blob_id_required_for_has_many}
  def select(attachments, %Target{attachment: %{type: :one}}, _blob_id, _all?),
    do: {:ok, attachments}

  def select(attachments, %Target{attachment: %{type: :many}}, _blob_id, true),
    do: {:ok, attachments}

  def select(attachments, %Target{attachment: %{type: :many}}, blob_id, _all?)
      when not is_nil(blob_id),
      do: {:ok, Enum.filter(attachments, &(&1.blob_id == blob_id))}

  def select(_attachments, %Target{attachment: %{type: :many}}, nil, _all?),
    do: {:error, :blob_id_required_for_has_many}

  @doc """
  Removes attachment rows, and with them each blob no other row references.

  - `:detach` removes the attachment rows only.
  - `:purge` also destroys each blob's variant rows, then the blob row, and
    returns a deletion per destroyed row. The files are not touched.
  - `:mark` sets `pending_purge` on each blob instead and enqueues the
    `:purge_blob` job for it.
  """
  @spec unlink([struct()], :detach | :purge | :mark, Target.t(), Scope.t()) ::
          {:ok, %{attachments: [struct()], deletions: [Purge.deletion()], marked: [struct()]}}
          | {:error, term()}
  def unlink(attachments, mode, %Target{} = target, %Scope{} = scope)
      when mode in [:detach, :purge, :mark] do
    result = %{attachments: [], deletions: [], marked: []}

    attachments
    |> Enum.reduce_while({:ok, result}, fn attachment, {:ok, acc} ->
      case unlink_one(attachment, mode, target, scope) do
        {:ok, destroyed, deletions, marked} ->
          {:cont,
           {:ok,
            %{
              attachments: [destroyed | acc.attachments],
              deletions: acc.deletions ++ deletions,
              marked: acc.marked ++ marked
            }}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, %{marked: [_ | _] = marked}} = ok ->
        AshOban.run_triggers(marked, :purge_blob)
        ok

      other ->
        other
    end
  end

  defp unlink_one(attachment, mode, target, scope) do
    destroy_opts = Scope.to_opts(scope, action: :destroy, return_destroyed?: true)

    with {:ok, destroyed} <- Ash.destroy(attachment, destroy_opts) do
      if mode == :detach do
        {:ok, destroyed, [], []}
      else
        remove_blob(destroyed, attachment.blob, mode, target, scope)
      end
    end
  end

  # The blob row can already be gone, for example after a manual delete; then
  # there is nothing left to remove.
  defp remove_blob(destroyed, nil, _mode, _target, _scope), do: {:ok, destroyed, [], []}

  defp remove_blob(destroyed, blob, mode, target, scope) do
    case Purge.referenced?(blob, target, scope) do
      {:ok, true} ->
        {:ok, destroyed, [], []}

      {:ok, false} when mode == :purge ->
        with {:ok, deletions} <- Purge.destroy_blob(blob, scope, target) do
          {:ok, destroyed, deletions, []}
        end

      {:ok, false} ->
        with {:ok, marked} <- Purge.mark(blob, scope) do
          {:ok, destroyed, [], [marked]}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Creates the attachment row that links `blob` to `record`."
  @spec insert_attachment(struct(), struct(), Target.t(), Scope.t()) ::
          {:ok, struct()} | {:error, term()}
  def insert_attachment(record, blob, %Target{} = target, %Scope{} = scope) do
    params = Map.new(Owner.keys(target, record) ++ [blob_id: blob.id])

    Ash.create(target.attachment_resource, params, Scope.to_opts(scope, action: :create))
  end
end
