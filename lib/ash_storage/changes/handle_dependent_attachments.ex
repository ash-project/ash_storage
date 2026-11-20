defmodule AshStorage.Changes.HandleDependentAttachments do
  @moduledoc false
  use Ash.Resource.Change

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Hooks, Scope}

  @impl true
  def change(changeset, _opts, context) do
    if changeset.action.soft? do
      changeset
    else
      async? = async_purge?(changeset.resource)

      changeset =
        changeset
        # Find attachments BEFORE the action runs, because ON DELETE SET NULL
        # will nilify the FK after the SQL DELETE executes, making them unfindable.
        |> Ash.Changeset.before_action(fn changeset ->
          case prefetch(changeset.data, Scope.from_change(changeset, context)) do
            {:ok, found} ->
              Ash.Changeset.put_context(changeset, :__ash_storage_attachments__, found)

            {:error, error} ->
              Ash.Changeset.add_error(changeset, error)
          end
        end)
        |> Ash.Changeset.after_action(fn changeset, record ->
          found = changeset.context[:__ash_storage_attachments__] || []
          scope = Scope.from_change(changeset, context)

          with {:ok, deletions} <- unlink_all(found, async?, scope) do
            {:ok, Hooks.defer_deletions(record, deletions, false)}
          end
        end)

      # The asynchronous purge leaves the files to the `:purge_blob` job. The
      # synchronous one always deletes in `after_transaction`, also inside a
      # transaction the caller opened: a later hook of this destroy can still
      # fail, and the rows would then survive the file.
      if async?, do: changeset, else: Hooks.delete_after_transaction(changeset, false)
    end
  end

  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end

  defp async_purge?(resource) do
    blob_resource = AshStorage.Info.storage_blob_resource!(resource)

    Code.ensure_loaded?(AshOban) &&
      Spark.Dsl.Extension.get_persisted(blob_resource, :extensions)
      |> List.wrap()
      |> Enum.member?(AshOban)
  end

  defp prefetch(record, scope) do
    record.__struct__
    |> AshStorage.Info.attachments()
    |> Enum.filter(&(&1.dependent in [:purge, :detach]))
    |> Enum.reduce_while({:ok, []}, fn attachment_def, {:ok, acc} ->
      with {:ok, target} <- Pipeline.resolve(record.__struct__, attachment_def.name),
           {:ok, attachments} <- Pipeline.attachments(record, target, scope) do
        {:cont, {:ok, acc ++ [{target, attachments}]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp unlink_all(found, async?, scope) do
    Enum.reduce_while(found, {:ok, []}, fn {target, attachments}, {:ok, acc} ->
      mode =
        case target.attachment.dependent do
          :detach -> :detach
          :purge when async? -> :mark
          :purge -> :purge
        end

      case Pipeline.unlink(attachments, mode, target, scope) do
        {:ok, %{deletions: deletions}} -> {:cont, {:ok, acc ++ deletions}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
