defmodule AshStorage.Pipeline.Purge do
  @moduledoc false
  # Removing blob rows and the files behind them. Rows go inside the action's
  # transaction; files are deleted from the deletions those steps return, after
  # the transaction has committed.

  require Ash.Query
  require Logger

  alias AshStorage.Pipeline.{Scope, Target}

  @type deletion :: {module(), AshStorage.Service.Context.t(), String.t()}

  @doc """
  Whether a row of the target's attachment resource that `scope` may read
  still references `blob`.
  """
  @spec referenced?(struct(), Target.t(), Scope.t()) :: {:ok, boolean()} | {:error, term()}
  def referenced?(blob, %Target{} = target, %Scope{} = scope) do
    target.attachment_resource
    |> Ash.Query.filter(blob_id == ^blob.id)
    |> Ash.Query.limit(1)
    |> Ash.read(Scope.to_opts(scope))
    |> case do
      {:ok, rows} -> {:ok, rows != []}
      {:error, _} = error -> error
    end
  end

  @doc """
  Destroys the variant rows of `blob`, then `blob`'s own row, and returns one
  deletion per destroyed row.
  """
  @spec destroy_blob(struct(), Scope.t(), Target.t() | nil) ::
          {:ok, [deletion()]} | {:error, term()}
  def destroy_blob(blob, %Scope{} = scope, target \\ nil) do
    with {:ok, deletions} <- destroy_variants(blob, scope, target),
         {:ok, _} <-
           Ash.destroy(blob, Scope.to_opts(scope, action: :destroy, return_destroyed?: true)) do
      {:ok, deletions ++ [deletion(blob, scope, target)]}
    end
  end

  @doc """
  Destroys the variant rows of `blob` and returns one deletion per row. A
  variant's row references its source, so it has to go first. With a target,
  a variant that one of its attachment rows references is kept.
  """
  @spec destroy_variants(struct(), Scope.t(), Target.t() | nil) ::
          {:ok, [deletion()]} | {:error, term()}
  def destroy_variants(blob, %Scope{} = scope, target \\ nil) do
    with {:ok, blob} <-
           Ash.load(
             blob,
             [variants: Scope.related(scope, blob.__struct__)],
             Scope.to_opts(scope)
           ) do
      Enum.reduce_while(blob.variants, {:ok, []}, fn variant, {:ok, acc} ->
        case destroy_variant(variant, scope, target) do
          {:ok, deletions} -> {:cont, {:ok, acc ++ deletions}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp destroy_variant(variant, scope, target) do
    with {:ok, false} <- referenced_with_target?(variant, scope, target),
         {:ok, _} <-
           Ash.destroy(variant, Scope.to_opts(scope, action: :destroy, return_destroyed?: true)) do
      {:ok, [deletion(variant, scope, target)]}
    else
      {:ok, true} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  # `:purge_blob` runs without a target, so it cannot know which attachment
  # resource to look in
  defp referenced_with_target?(_variant, _scope, nil), do: {:ok, false}
  defp referenced_with_target?(variant, scope, target), do: referenced?(variant, target, scope)

  @doc "Sets `pending_purge` on `blob`, for the `:purge_blob` job to remove it."
  @spec mark(struct(), Scope.t()) :: {:ok, struct()} | {:error, term()}
  def mark(blob, %Scope{} = scope) do
    Ash.update(
      blob,
      %{pending_purge: true},
      Scope.to_opts(scope, action: :mark_for_purge, return_record?: true)
    )
  end

  @doc """
  Deletes the files. The rows are gone by now, so a file that cannot be
  deleted is logged and left in the store rather than failing anything.
  """
  @spec delete_files([deletion()]) :: :ok
  def delete_files(deletions) do
    Enum.each(deletions, fn {service_mod, ctx, key} ->
      case service_mod.delete(key, ctx) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "AshStorage could not delete #{inspect(key)} from #{inspect(service_mod)}: " <>
              inspect(reason)
          )
      end
    end)
  end

  defp deletion(blob, scope, target) do
    {blob.service_name, Target.blob_context(blob, scope, target), blob.key}
  end
end
