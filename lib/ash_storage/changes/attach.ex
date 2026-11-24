defmodule AshStorage.Changes.Attach do
  @moduledoc false
  use Ash.Resource.Change

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Hooks, Scope, Source, Target}

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, opts, context) do
    attachment_name = opts[:attachment_name]
    nested? = Hooks.nested?(changeset)

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      record = changeset.data
      scope = Scope.from_change(changeset, context)

      case do_attach(record, attachment_name, changeset, scope) do
        {:ok, attrs_to_write, attach_context} ->
          changeset
          |> Ash.Changeset.force_change_attributes(attrs_to_write)
          |> Ash.Changeset.put_context(:__ash_storage_attach__, attach_context)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      case changeset.context[:__ash_storage_attach__] do
        %{blob: blob, target: target} = attach_context ->
          scope = Scope.from_change(changeset, context)

          with {:ok, deletions} <- replace_existing(record, target, scope),
               {:ok, attachment} <- Pipeline.insert_attachment(record, blob, target, scope),
               :ok <- run_eager_variants(blob, target, scope),
               {:ok, blob} <- store_oban_variants(blob, target, scope) do
            if attach_context[:has_oban_analyzers?] do
              AshOban.run_trigger(blob, :run_pending_analyzers, tenant: scope.tenant)
            end

            if has_oban_variants?(target.attachment) do
              AshOban.run_trigger(blob, :run_pending_variants, tenant: scope.tenant)
            end

            record =
              record
              |> Ash.Resource.put_metadata(:blob, blob)
              |> Ash.Resource.put_metadata(:attachment, attachment)
              |> Hooks.defer_deletions(deletions, nested?)

            {:ok, record}
          end

        _ ->
          {:ok, record}
      end
    end)
    |> Hooks.delete_after_transaction(nested?)
  end

  defp do_attach(record, attachment_name, changeset, scope) do
    io = Ash.Changeset.get_argument(changeset, :io)
    filename = Ash.Changeset.get_argument(changeset, :filename)

    content_type =
      Ash.Changeset.get_argument(changeset, :content_type) || "application/octet-stream"

    metadata = Ash.Changeset.get_argument(changeset, :metadata) || %{}

    with {:ok, target} <- Pipeline.resolve(record.__struct__, attachment_name),
         source =
           Source.new(io, filename: filename, content_type: content_type, metadata: metadata),
         {:ok, blob, :stored} <- Pipeline.store(source, target, scope, changeset),
         {:ok, blob, attrs_to_write} <- Pipeline.analyze(blob, source, target, scope, record) do
      {:ok, attrs_to_write,
       %{
         blob: blob,
         target: target,
         has_oban_analyzers?: has_oban_analyzers?(target.attachment)
       }}
    end
  end

  defp has_oban_analyzers?(attachment_def) do
    analyzer_defs = attachment_def.analyzers || []

    Enum.any?(analyzer_defs, fn defn ->
      defn.analyze == :oban
    end)
  end

  # -- Attachment helpers --

  # Replacing a has_one file removes the old one through the shared purge; the
  # old files are deleted once the transaction has committed.
  defp replace_existing(record, %Target{attachment: %{type: :one}} = target, scope) do
    with {:ok, existing} <- Pipeline.attachments(record, target, scope),
         {:ok, %{deletions: deletions}} <- Pipeline.unlink(existing, :purge, target, scope) do
      {:ok, deletions}
    end
  end

  defp replace_existing(_record, %Target{attachment: %{type: :many}}, _scope), do: {:ok, []}

  # -- Variant helpers --

  defp run_eager_variants(blob, target, scope) do
    eager_variants =
      (target.attachment.variants || [])
      |> Enum.filter(&(&1.generate == :eager))

    Enum.reduce_while(eager_variants, :ok, fn variant_def, :ok ->
      case AshStorage.VariantGenerator.generate(blob, variant_def, target, scope) do
        {:ok, _variant_blob} -> {:cont, :ok}
        {:error, :not_accepted} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp has_oban_variants?(attachment_def) do
    (attachment_def.variants || [])
    |> Enum.any?(&(&1.generate == :oban))
  end

  defp store_oban_variants(blob, %Target{attachment: attachment_def} = target, scope) do
    oban_variants =
      (attachment_def.variants || [])
      |> Enum.filter(&(&1.generate == :oban))

    if oban_variants == [] do
      {:ok, blob}
    else
      pending_variants =
        Map.new(oban_variants, fn variant_def ->
          {mod, opts} = AshStorage.VariantDefinition.normalize(variant_def)
          string_opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

          {to_string(variant_def.name),
           %{
             "status" => "pending",
             "module" => to_string(mod),
             "opts" => string_opts,
             "resource" => to_string(target.resource),
             "attachment" => to_string(attachment_def.name)
           }}
        end)

      metadata = Map.put(blob.metadata || %{}, "__pending_variants__", pending_variants)

      Ash.update(
        blob,
        %{metadata: metadata, pending_variants: true},
        Scope.to_opts(scope, action: :update_metadata)
      )
    end
  end
end
