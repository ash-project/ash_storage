defmodule AshStorage.BlobResource.Changes.RunPendingVariants do
  @moduledoc """
  Multi-unit dispatcher: runs a single variant, every pending member of a
  named group, or both — group first, then the lone variant — within the
  same Oban job.

  Used by the `:run_pending_variants` action. At least one of the action
  arguments `:variant_name` or `:group` must be set; both may be set.

  Per-variant work is fully delegated to the `:run_pending_variant` action,
  which handles generation, atomic completion, and tier advancement. This
  change only orchestrates which variants get invoked.
  """
  use Ash.Resource.Change

  @pending_key "__pending_variants__"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, blob ->
      variant_name = Ash.Changeset.get_argument(changeset, :variant_name)
      group = Ash.Changeset.get_argument(changeset, :group)

      case {variant_name, group} do
        {nil, nil} ->
          {:error, :run_pending_variants_requires_variant_name_or_group}

        {variant_name, nil} when is_binary(variant_name) ->
          Ash.update(blob, %{variant_name: variant_name}, action: :run_pending_variant)

        {nil, group} when is_binary(group) ->
          run_group(blob, group)

        {variant_name, group} when is_binary(variant_name) and is_binary(group) ->
          with {:ok, blob} <- run_group(blob, group) do
            Ash.update(blob, %{variant_name: variant_name}, action: :run_pending_variant)
          end
      end
    end)
  end

  defp run_group(blob, group) do
    members =
      blob.metadata
      |> Kernel.||(%{})
      |> Map.get(@pending_key, %{})
      |> Enum.filter(fn {_name, info} ->
        info["status"] == "pending" and to_string(info["group"] || "") == group
      end)

    Enum.reduce_while(members, {:ok, blob}, fn {variant_name, _info}, {:ok, blob} ->
      case Ash.update(blob, %{variant_name: variant_name}, action: :run_pending_variant) do
        {:ok, blob} -> {:cont, {:ok, blob}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
