defmodule AshStorage.BlobResource.Changes.RunPendingVariant do
  @moduledoc """
  A change that generates a single pending variant for a blob.

  Used by the `:run_pending_variant` action, typically invoked as a per-variant
  Oban job (one job per variant) so that variants run in parallel and have
  independent retry lifecycles.

  Looks up the variant entry inside `metadata["__pending_variants__"]` by name,
  rehydrates the module/opts/resource/attachment, generates the variant via
  `AshStorage.VariantGenerator`, and atomically records the result via the
  `:complete_variant` action.

  Idempotent: if the named entry is missing or already non-pending, the action
  returns the blob unchanged so re-enqueued jobs are safe.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, blob ->
      variant_name = Ash.Changeset.get_argument(changeset, :variant_name)
      pending_variants = blob.metadata["__pending_variants__"] || %{}

      case Map.get(pending_variants, variant_name) do
        %{"status" => "pending"} = info -> run(blob, variant_name, info)
        _ -> {:ok, blob}
      end
    end)
  end

  defp run(blob, variant_name, info) do
    resource = String.to_existing_atom(info["resource"])
    attachment = String.to_existing_atom(info["attachment"])
    name = String.to_existing_atom(variant_name)
    module = String.to_existing_atom(info["module"])
    opts = Enum.map(info["opts"], fn {k, v} -> {String.to_existing_atom(k), v} end)
    fields = %{name: name, module: {module, opts}, generate: :oban}
    variant_def = struct(AshStorage.VariantDefinition, fields)
    {:ok, attachment_def} = AshStorage.Info.attachment(resource, attachment)

    case AshStorage.VariantGenerator.generate(blob, variant_def, resource, attachment_def) do
      {:ok, _variant_blob} -> complete(blob, variant_name, "complete")
      {:error, :not_accepted} -> complete(blob, variant_name, "skipped")
      {:error, error} -> {:error, error}
    end
  end

  defp complete(blob, variant_name, status) do
    Ash.update(blob, %{variant_name: variant_name, status: status}, action: :complete_variant)
  end
end
