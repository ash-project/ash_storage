defmodule AshStorage.BlobResource.Changes.CompleteAnalysis do
  @moduledoc """
  A change that atomically updates a blob's analyzer status and merges metadata.

  Used by the `:complete_analysis` action. On SQL data layers, this uses
  `jsonb_set` and `||` fragments for true atomic updates, preventing race
  conditions when multiple async analyzer jobs complete concurrently.

  On non-SQL data layers (e.g. ETS), falls back to in-memory map manipulation.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      analyzer_key = Ash.Changeset.get_argument(changeset, :analyzer_key)
      status = Ash.Changeset.get_argument(changeset, :status)
      metadata_to_merge = Ash.Changeset.get_argument(changeset, :metadata_to_merge) || %{}

      record = changeset.data
      current_analyzers = record.analyzers || %{}
      current_metadata = record.metadata || %{}

      updated_analyzers =
        put_entry(
          current_analyzers,
          analyzer_key,
          status,
          Ash.Changeset.get_argument(changeset, :error)
        )

      updated_metadata = Map.merge(current_metadata, metadata_to_merge)

      still_pending? =
        Enum.any?(updated_analyzers, fn {_key, info} ->
          info["status"] == "pending"
        end)

      changeset
      |> Ash.Changeset.force_change_attribute(:analyzers, updated_analyzers)
      |> Ash.Changeset.force_change_attribute(:metadata, updated_metadata)
      |> then(fn cs ->
        if still_pending?,
          do: cs,
          else: Ash.Changeset.force_change_attribute(cs, :pending_analyzers, false)
      end)
    end)
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    if Ash.DataLayer.data_layer(changeset.resource) == AshPostgres.DataLayer do
      do_atomic(changeset)
    else
      do_non_atomic(changeset)
    end
  end

  defp do_non_atomic(changeset) do
    analyzer_key = Ash.Changeset.get_argument(changeset, :analyzer_key)
    status = Ash.Changeset.get_argument(changeset, :status)
    metadata_to_merge = Ash.Changeset.get_argument(changeset, :metadata_to_merge) || %{}

    record = changeset.data
    current_analyzers = record.analyzers || %{}
    current_metadata = record.metadata || %{}

    updated_analyzers =
      put_entry(
        current_analyzers,
        analyzer_key,
        status,
        Ash.Changeset.get_argument(changeset, :error)
      )

    updated_metadata = Map.merge(current_metadata, metadata_to_merge)

    still_pending? =
      Enum.any?(updated_analyzers, fn {_key, info} ->
        info["status"] == "pending"
      end)

    atomics = %{
      analyzers: {:atomic, updated_analyzers},
      metadata: {:atomic, updated_metadata}
    }

    if still_pending? do
      {:atomic, atomics}
    else
      {:atomic, Map.put(atomics, :pending_analyzers, {:atomic, false})}
    end
  end

  defp do_atomic(changeset) do
    analyzer_key = Ash.Changeset.get_argument(changeset, :analyzer_key)
    status = Ash.Changeset.get_argument(changeset, :status)
    metadata_to_merge = Ash.Changeset.get_argument(changeset, :metadata_to_merge) || %{}

    analyzers_expr =
      case Ash.Changeset.get_argument(changeset, :error) do
        nil ->
          Ash.Expr.expr(
            fragment(
              "jsonb_set(coalesce(?, '{}'), ?::text[], to_jsonb(?::text)) #- ?::text[]",
              analyzers,
              ^[analyzer_key, "status"],
              ^status,
              ^[analyzer_key, "error"]
            )
          )

        error ->
          Ash.Expr.expr(
            fragment(
              "jsonb_set(jsonb_set(coalesce(?, '{}'), ?::text[], to_jsonb(?::text)), ?::text[], to_jsonb(?::text))",
              analyzers,
              ^[analyzer_key, "status"],
              ^status,
              ^[analyzer_key, "error"],
              ^error
            )
          )
      end

    atomics = %{analyzers: {:atomic, analyzers_expr}}

    atomics =
      if metadata_to_merge != %{} do
        Map.put(
          atomics,
          :metadata,
          {:atomic,
           Ash.Expr.expr(
             fragment(
               "coalesce(?, '{}') || ?",
               metadata,
               ^metadata_to_merge
             )
           )}
        )
      else
        atomics
      end

    # Atomically clear pending_analyzers if no entries remain with status 'pending'
    # after this update. The subquery checks the updated jsonb value.
    atomics =
      Map.put(
        atomics,
        :pending_analyzers,
        {:atomic,
         Ash.Expr.expr(
           fragment(
             "EXISTS (SELECT 1 FROM jsonb_each(jsonb_set(coalesce(?, '{}'), ?::text[], to_jsonb(?::text))) AS a WHERE a.value->>'status' = 'pending')",
             analyzers,
             ^[analyzer_key, "status"],
             ^status
           )
         )}
      )

    {:atomic, atomics}
  end

  # An outcome without an error clears the reason an earlier failure left
  defp put_entry(analyzers, analyzer_key, status, nil) do
    analyzers
    |> put_in([analyzer_key, "status"], status)
    |> update_in([analyzer_key], &Map.delete(&1, "error"))
  end

  defp put_entry(analyzers, analyzer_key, status, error) do
    analyzers
    |> put_in([analyzer_key, "status"], status)
    |> put_in([analyzer_key, "error"], error)
  end
end
