defmodule AshStorage.Changes.HandleFileArgument do
  @moduledoc false
  use Ash.Resource.Change

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Analysis, Hooks, Scope, Source, Target}

  @impl true
  def init(opts), do: {:ok, opts}

  # sobelow_skip ["DOS.BinToAtom"]
  @impl true
  def change(changeset, opts, context) do
    argument_name = opts[:argument]
    attachment_name = opts[:attachment]

    file = Ash.Changeset.get_argument(changeset, argument_name)
    nested? = Hooks.nested?(changeset)

    if is_nil(file) do
      changeset
    else
      changeset
      |> Ash.Changeset.before_action(fn changeset ->
        scope = Scope.from_change(changeset, context)

        case upload_blob(changeset.resource, attachment_name, file, changeset, scope) do
          {:ok, attrs_to_write, state} ->
            changeset
            |> Ash.Changeset.force_change_attributes(attrs_to_write)
            |> Ash.Changeset.put_context(:"__ash_storage_file_arg_#{argument_name}__", state)

          {:error, error} ->
            Ash.Changeset.add_error(changeset, error)
        end
      end)
      |> Ash.Changeset.after_action(fn changeset, record ->
        context_key = :"__ash_storage_file_arg_#{argument_name}__"

        case changeset.context[context_key] do
          %{blob: blob, target: target} = state ->
            scope = Scope.from_change(changeset, context)

            # On update, replace existing attachment; on create, skip
            with {:ok, deletions} <- replace_on_update(changeset, record, target, scope),
                 {:ok, attachment} <- Pipeline.insert_attachment(record, blob, target, scope),
                 # A create learns the record's key only now
                 {:ok, blob} <- Analysis.bind_write_target(blob, target, record, scope) do
              if state[:has_oban_analyzers?] do
                AshOban.run_trigger(blob, :run_pending_analyzers, tenant: scope.tenant)
              end

              record =
                record
                |> Ash.Resource.put_metadata(:"#{attachment_name}_blob", blob)
                |> Ash.Resource.put_metadata(:"#{attachment_name}_attachment", attachment)
                |> Hooks.defer_deletions(deletions, nested?)

              {:ok, record}
            end

          _ ->
            {:ok, record}
        end
      end)
      |> Hooks.delete_after_transaction(nested?)
    end
  end

  defp replace_on_update(%{action_type: :create}, _record, _target, _scope), do: {:ok, []}

  defp replace_on_update(_changeset, record, target, scope),
    do: replace_existing(record, target, scope)

  defp upload_blob(resource, attachment_name, file, changeset, scope) do
    with {:ok, target} <- Pipeline.resolve(resource, attachment_name),
         source = Source.new(file),
         {:ok, blob, :stored} <- Pipeline.store(source, target, scope, changeset),
         {:ok, blob, attrs_to_write} <-
           Pipeline.analyze(blob, source, target, scope, changeset.data) do
      {:ok, attrs_to_write,
       %{
         blob: blob,
         target: target,
         has_oban_analyzers?: has_oban_analyzers?(target.attachment)
       }}
    end
  end

  # -- Shared helpers (same as Changes.Attach) --

  defp has_oban_analyzers?(attachment_def) do
    Enum.any?(attachment_def.analyzers || [], fn defn -> defn.analyze == :oban end)
  end

  # Replacing a has_one file removes the old one through the shared purge; the
  # old files are deleted once the transaction has committed.
  defp replace_existing(record, %Target{attachment: %{type: :one}} = target, scope) do
    with {:ok, existing} <- Pipeline.attachments(record, target, scope),
         {:ok, %{deletions: deletions}} <- Pipeline.unlink(existing, :purge, target, scope) do
      {:ok, deletions}
    end
  end

  defp replace_existing(_record, %Target{attachment: %{type: :many}}, _scope), do: {:ok, []}
end
