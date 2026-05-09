defmodule AshStorage.BlobResource.Changes.CompleteVariant do
  @moduledoc """
  A change that atomically updates a single variant's status inside the blob's
  `metadata["__pending_variants__"]` map and clears the `pending_variants`
  flag when no entries remain with `"status" => "pending"`.

  Used by the `:complete_variant` action. On `AshPostgres.DataLayer`, this
  uses `jsonb_set` and an `EXISTS` subquery for true atomic updates,
  preventing race conditions when multiple per-variant Oban jobs complete
  concurrently. On non-SQL data layers (e.g. ETS), falls back to in-memory
  map manipulation.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @pending_key "__pending_variants__"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      variant_name = Ash.Changeset.get_argument(changeset, :variant_name)
      status = Ash.Changeset.get_argument(changeset, :status)

      record = changeset.data
      current_metadata = record.metadata || %{}
      current_pending = Map.get(current_metadata, @pending_key, %{})

      updated_pending = put_in(current_pending, [variant_name, "status"], status)
      updated_metadata = Map.put(current_metadata, @pending_key, updated_pending)

      still_pending? =
        Enum.any?(updated_pending, fn {_name, info} ->
          info["status"] == "pending"
        end)

      changeset
      |> Ash.Changeset.force_change_attribute(:metadata, updated_metadata)
      |> then(fn cs ->
        if still_pending?,
          do: cs,
          else: Ash.Changeset.force_change_attribute(cs, :pending_variants, false)
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
    variant_name = Ash.Changeset.get_argument(changeset, :variant_name)
    status = Ash.Changeset.get_argument(changeset, :status)

    record = changeset.data
    current_metadata = record.metadata || %{}
    current_pending = Map.get(current_metadata, @pending_key, %{})

    updated_pending = put_in(current_pending, [variant_name, "status"], status)
    updated_metadata = Map.put(current_metadata, @pending_key, updated_pending)

    still_pending? =
      Enum.any?(updated_pending, fn {_name, info} ->
        info["status"] == "pending"
      end)

    atomics = %{metadata: {:atomic, updated_metadata}}

    if still_pending? do
      {:atomic, atomics}
    else
      {:atomic, Map.put(atomics, :pending_variants, {:atomic, false})}
    end
  end

  defp do_atomic(changeset) do
    variant_name = Ash.Changeset.get_argument(changeset, :variant_name)
    status = Ash.Changeset.get_argument(changeset, :status)

    atomics = %{
      metadata:
        {:atomic,
         Ash.Expr.expr(
           fragment(
             "jsonb_set(coalesce(?, '{}'), ?::text[], to_jsonb(?::text))",
             metadata,
             ^[@pending_key, variant_name, "status"],
             ^status
           )
         )}
    }

    # Atomically clear pending_variants if no entries remain with status
    # 'pending' inside metadata->'__pending_variants__' after this update.
    atomics =
      Map.put(
        atomics,
        :pending_variants,
        {:atomic,
         Ash.Expr.expr(
           fragment(
             "EXISTS (SELECT 1 FROM jsonb_each(jsonb_set(coalesce(?, '{}'), ?::text[], to_jsonb(?::text))->?) AS v WHERE v.value->>'status' = 'pending')",
             metadata,
             ^[@pending_key, variant_name, "status"],
             ^status,
             ^@pending_key
           )
         )}
      )

    {:atomic, atomics}
  end
end
