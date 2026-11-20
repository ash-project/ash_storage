defmodule AshStorage.BlobResource.Changes.RunPendingAnalyzers do
  @moduledoc """
  A change that runs all pending analyzers for a blob.

  Used by the `:run_pending_analyzers` action, typically triggered by AshOban.
  Iterates through the blob's analyzers map, finds any with `"status" => "pending"`,
  and runs each one via `AshStorage.Operations.run_analyzer/2`.
  """
  use Ash.Resource.Change

  alias AshStorage.Pipeline.Scope

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, blob ->
      opts = changeset |> Scope.from_change(context) |> Scope.to_opts()
      analyzers = blob.analyzers || %{}

      pending =
        Enum.filter(analyzers, fn {_mod, info} ->
          info["status"] == "pending"
        end)

      Enum.reduce_while(pending, {:ok, blob}, fn {analyzer_mod, _info}, {:ok, blob} ->
        # sobelow_skip ["DOS.BinToAtom"]
        module = String.to_existing_atom(analyzer_mod)

        case AshStorage.Operations.run_analyzer(blob, module, opts) do
          {:ok, blob} -> {:cont, {:ok, blob}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end)
  end
end
