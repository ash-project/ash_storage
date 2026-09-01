defmodule AshStorage.Verifiers.ValidateBlobIOLayers do
  @moduledoc false
  # Compile-time guard: a blob's correct read depends on every layer in
  # its effective chain resolving to a UNIQUE layer_metadata_key. Two layers that
  # share a key collide: both write metadata, but the read index can only keep
  # one, so one layer runs twice and the other not at all. For encryption that is
  # a silent wrong/failed decrypt. This verifier rejects such configurations at
  # compile time; `AshStorage.BlobIO.Layers` enforces the same invariant at
  # runtime for explicit per-call `:layers` handoffs the DSL can't see.
  use Spark.Dsl.Verifier

  alias AshStorage.Layer

  def verify(dsl_state) do
    attachments =
      AshStorage.Info.has_one_attachments(dsl_state) ++
        AshStorage.Info.has_many_attachments(dsl_state)

    Enum.reduce_while(attachments, :ok, fn attachment, :ok ->
      case validate_attachment(dsl_state, attachment) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_attachment(dsl_state, attachment) do
    duplicate_keys =
      dsl_state
      |> AshStorage.Info.layers_for_attachment(attachment)
      |> Enum.flat_map(&resolve_key/1)
      |> duplicates()

    case duplicate_keys do
      [] -> :ok
      keys -> {:error, duplicate_error(attachment, keys)}
    end
  end

  # Resolve a layer spec's metadata key. Skip modules not yet loaded/implementing
  # the callback: those can't be checked here and are caught by the runtime guard.
  defp resolve_key(spec) do
    {module, opts} =
      case spec do
        module when is_atom(module) -> {module, []}
        {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
      end

    if Code.ensure_loaded?(module) and function_exported?(module, :default_metadata_key, 1) do
      [Layer.layer_metadata_key({module, opts})]
    else
      []
    end
  end

  defp duplicates(keys) do
    (keys -- Enum.uniq(keys)) |> Enum.uniq()
  end

  defp duplicate_error(attachment, keys) do
    Spark.Error.DslError.exception(
      message: """
      Attachment #{inspect(attachment.name)} has layers that resolve to \
      duplicate layer metadata key(s): #{Enum.map_join(keys, ", ", &inspect/1)}.

      Each layer in an attachment's effective chain (resource-level layers first, \
      then attachment-level layers) must resolve to a unique `metadata_key`. Two \
      layers sharing a key collide on read: only one is indexed, so the other \
      cannot interpret its persisted metadata. Give each layer a distinct \
      `metadata_key` (note the encryption layer defaults to "encryption").
      """
    )
  end
end
