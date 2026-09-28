defmodule AshStorage.BlobResource.Changes.RunPendingVariants do
  @moduledoc """
  A change that generates all pending variants for a blob.

  Used by the `:run_pending_variants` action, typically triggered by AshOban.
  Iterates through the blob's pending_variants map, finds any with `"status" => "pending"`,
  and generates each one via `AshStorage.VariantGenerator`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    context_opts = Ash.Context.to_opts(context)

    Ash.Changeset.after_action(changeset, fn _changeset, blob ->
      pending_variants = blob.metadata["__pending_variants__"] || %{}

      pending =
        Enum.filter(pending_variants, fn {_name, info} ->
          info["status"] == "pending"
        end)

      Enum.reduce_while(pending, {:ok, blob}, fn {variant_name, info}, {:ok, blob} ->
        # sobelow_skip ["DOS.BinToAtom"]
        module = String.to_existing_atom(info["module"])
        opts = deserialize_opts(info["opts"] || %{})
        resource_module = String.to_existing_atom(info["resource"])
        attachment_name = String.to_existing_atom(info["attachment"])

        {:ok, attachment_def} = AshStorage.Info.attachment(resource_module, attachment_name)

        variant_def = %AshStorage.VariantDefinition{
          name: String.to_existing_atom(variant_name),
          module: if(opts == [], do: module, else: {module, opts}),
          generate: :oban
        }

        new_status =
          case AshStorage.VariantGenerator.generate(
                 blob,
                 variant_def,
                 resource_module,
                 attachment_def
               ) do
            {:ok, _variant_blob} -> "complete"
            {:error, :not_accepted} -> "skipped"
            {:error, error} -> {:halt_error, error}
          end

        case new_status do
          {:halt_error, error} ->
            {:halt, {:error, error}}

          status ->
            updated_variants =
              put_in(pending_variants, [variant_name, "status"], status)

            still_pending? =
              Enum.any?(updated_variants, fn {_k, v} -> v["status"] == "pending" end)

            metadata = Map.put(blob.metadata, "__pending_variants__", updated_variants)

            update_params =
              if still_pending? do
                %{metadata: metadata}
              else
                %{metadata: metadata, pending_variants: false}
              end

            case Ash.update(
                   blob,
                   update_params,
                   Keyword.merge(context_opts, action: :update_metadata)
                 ) do
              {:ok, blob} -> {:cont, {:ok, blob}}
              {:error, error} -> {:halt, {:error, error}}
            end
        end
      end)
    end)
  end

  defp deserialize_opts(opts_map) when is_map(opts_map) do
    Enum.map(opts_map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp deserialize_opts(_), do: []
end
