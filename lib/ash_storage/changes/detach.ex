defmodule AshStorage.Changes.Detach do
  @moduledoc false
  use Ash.Resource.Change

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.Scope

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, context) do
    attachment_name = opts[:attachment_name]

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      scope = Scope.from_change(changeset, context)
      blob_id = Ash.Changeset.get_argument(changeset, :blob_id)
      all? = Ash.Changeset.get_argument(changeset, :all) || false

      with {:ok, target} <- Pipeline.resolve(record.__struct__, attachment_name),
           {:ok, attachments} <- Pipeline.attachments(record, target, scope),
           {:ok, to_detach} <- select_for_detach(attachments, target.attachment, blob_id, all?) do
        case destroy_attachment_records(to_detach, scope) do
          {:ok, destroyed} ->
            {:ok, Ash.Resource.put_metadata(record, :detached_attachments, destroyed)}

          {:error, error} ->
            {:error, error}
        end
      end
    end)
  end

  defp select_for_detach(attachments, %{type: :one}, _blob_id, _all?), do: {:ok, attachments}

  defp select_for_detach(attachments, %{type: :many}, _blob_id, true), do: {:ok, attachments}

  defp select_for_detach(attachments, %{type: :many}, blob_id, _all?) when not is_nil(blob_id) do
    {:ok, Enum.filter(attachments, &(&1.blob_id == blob_id))}
  end

  defp select_for_detach(_attachments, %{type: :many}, nil, false) do
    {:error, :blob_id_required_for_has_many}
  end

  defp destroy_attachment_records(attachments, scope) do
    destroy_opts = Scope.to_opts(scope, action: :destroy, return_destroyed?: true)

    Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
      case Ash.destroy(att, destroy_opts) do
        {:ok, destroyed} -> {:cont, {:ok, [destroyed | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
