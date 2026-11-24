defmodule AshStorage.Changes.HandleFileArgument do
  @moduledoc false
  use Ash.Resource.Change

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Hooks, Owner, Scope, Source, Target}

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
                 {:ok, attachment} <- Pipeline.insert_attachment(record, blob, target, scope) do
              # Now that we have the record ID, update write_target for oban analyzers
              if state[:has_oban_analyzers?] do
                update_oban_write_targets(blob, record, target, scope)
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
           run_analyzers(blob, target, changeset.data, source, scope) do
      {:ok, attrs_to_write,
       %{
         blob: blob,
         target: target,
         has_oban_analyzers?: has_oban_analyzers?(target.attachment)
       }}
    end
  end

  # After create, we have the real record ID — update write_target in blob's analyzers map
  defp update_oban_write_targets(blob, record, target, scope) do
    analyzers = blob.analyzers || %{}

    has_write_targets? =
      Enum.any?(analyzers, fn {_key, entry} -> Map.has_key?(entry, "write_target") end)

    if has_write_targets? do
      updated =
        Map.new(analyzers, fn {key, entry} ->
          case entry do
            %{"write_target" => _} ->
              {key,
               Map.put(
                 entry,
                 "write_target",
                 target |> Owner.write_target(record) |> maybe_put_tenant(scope.tenant)
               )}

            _ ->
              {key, entry}
          end
        end)

      Ash.update(
        blob,
        %{analyzers: updated},
        Scope.to_opts(scope, action: :update_metadata)
      )
    end
  end

  # -- Shared helpers (same as Changes.Attach) --

  defp has_oban_analyzers?(attachment_def) do
    Enum.any?(attachment_def.analyzers || [], fn defn -> defn.analyze == :oban end)
  end

  defp run_analyzers(blob, target, record, source, scope) do
    analyzer_defs = target.attachment.analyzers || []

    if analyzer_defs == [] do
      {:ok, blob, %{}}
    else
      normalized = AshStorage.AttachmentDefinition.normalize_analyzers(analyzer_defs)
      content_type = blob.content_type || "application/octet-stream"

      initial_analyzers =
        Map.new(normalized, fn {module, _analyze, opts, write_attributes} ->
          string_opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

          entry =
            %{"status" => "pending", "opts" => string_opts}
            |> maybe_put_tenant(scope.tenant)

          entry =
            if write_attributes != [] do
              string_wa =
                Map.new(write_attributes, fn {k, v} -> {to_string(k), to_string(v)} end)

              entry
              |> Map.put("write_attributes", string_wa)
              |> Map.put(
                "write_target",
                target |> Owner.write_target(record) |> maybe_put_tenant(scope.tenant)
              )
            else
              entry
            end

          {to_string(module), entry}
        end)

      with {:ok, blob} <-
             Ash.update(
               blob,
               %{analyzers: initial_analyzers},
               Scope.to_opts(scope, action: :update_metadata)
             ) do
        eager =
          Enum.filter(normalized, fn {module, analyze, _opts, _wa} ->
            analyze != :oban && module.accept?(content_type)
          end)

        run_eager_analyzers(blob, eager, source, scope)
      end
    end
  end

  defp run_eager_analyzers(blob, [], _source, _scope), do: {:ok, blob, %{}}

  defp run_eager_analyzers(blob, eager_analyzers, source, scope) do
    Source.with_local_path(source, fn path ->
      Enum.reduce_while(eager_analyzers, {:ok, blob, %{}}, fn {module, _analyze, opts,
                                                               write_attributes},
                                                              {:ok, blob, acc_writes} ->
        analyzer_key = to_string(module)

        {status, metadata_to_merge} =
          case module.analyze(path, opts) do
            {:ok, result} -> {"complete", result}
            {:error, _reason} -> {"error", %{}}
          end

        new_writes =
          if status == "complete" && write_attributes != [] do
            Enum.reduce(write_attributes, %{}, fn {result_key, attr_name}, acc ->
              case Map.fetch(metadata_to_merge, to_string(result_key)) do
                {:ok, value} -> Map.put(acc, attr_name, value)
                :error -> acc
              end
            end)
          else
            %{}
          end

        case Ash.update(
               blob,
               %{
                 analyzer_key: analyzer_key,
                 status: status,
                 metadata_to_merge: metadata_to_merge
               },
               Scope.to_opts(scope, action: :complete_analysis)
             ) do
          {:ok, blob} -> {:cont, {:ok, blob, Map.merge(acc_writes, new_writes)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end)
  end

  defp maybe_put_tenant(map, nil), do: map
  defp maybe_put_tenant(map, tenant), do: Map.put(map, "tenant", tenant)

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
