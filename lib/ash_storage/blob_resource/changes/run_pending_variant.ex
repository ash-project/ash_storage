defmodule AshStorage.BlobResource.Changes.RunPendingVariant do
  @moduledoc """
  Runs a single named variant: generates it via `AshStorage.VariantGenerator`,
  atomically marks it complete via `:complete_variant`, then advances the
  dispatch tier via `AshStorage.VariantScheduler.schedule_next/2`.

  Used by the `:run_pending_variant` action — the canonical "one variant"
  entry point, invoked both directly (from the scheduler) and indirectly
  (delegated to from `:run_pending_variants`).

  Idempotent: a missing or already-non-pending entry is a no-op so re-enqueued
  jobs are safe.
  """
  use Ash.Resource.Change

  @pending_key "__pending_variants__"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, blob ->
      variant_name = Ash.Changeset.get_argument(changeset, :variant_name)
      pending = blob.metadata["__pending_variants__"] || %{}
      info = Map.get(pending, variant_name)

      with :ok <- if(info["status"] == "pending", do: :ok, else: {:ok, blob}),
           {:ok, blob} <- generate_one(blob, variant_name, info),
           :ok <- AshStorage.VariantScheduler.schedule_next(blob, info["order"] || 0) do
        {:ok, blob}
      end
    end)
  end

  defp generate_one(blob, variant_name, info) do
    resource = String.to_existing_atom(info["resource"])
    attachment = String.to_existing_atom(info["attachment"])
    name = String.to_existing_atom(variant_name)
    module = String.to_existing_atom(info["module"])
    opts = Enum.map(info["opts"] || [], fn {k, v} -> {String.to_existing_atom(k), v} end)

    variant_def =
      struct(AshStorage.VariantDefinition,
        name: name,
        module: {module, opts},
        generate: :oban,
        group: info["group"] && String.to_existing_atom(info["group"]),
        order: info["order"] || 0
      )

    {:ok, attachment_def} = AshStorage.Info.attachment(resource, attachment)

    case AshStorage.VariantGenerator.generate(blob, variant_def, resource, attachment_def) do
      {:ok, _variant_blob} ->
        Ash.update(blob, %{variant_name: variant_name, status: "complete"},
          action: :complete_variant
        )

      {:error, :not_accepted} ->
        Ash.update(blob, %{variant_name: variant_name, status: "skipped"},
          action: :complete_variant
        )

      {:error, error} ->
        {:error, error}
    end
  end
end
