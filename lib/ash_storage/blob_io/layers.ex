defmodule AshStorage.BlobIO.Layers do
  @moduledoc false
  # Layer-chain runner. Connects runtime layer specs (modules/options) to the
  # persisted layer-metadata keys on a blob: normalizes specs, orders them
  # (configured order on write, reverse persisted order on read), invokes the
  # phase callback, fails closed on a persisted layer with no runtime match, and
  # guards against duplicate metadata keys.

  alias AshStorage.Layer

  @doc """
  Run all layers that implement the given phase callback.

  Missing optional callbacks are skipped. Callback errors are returned
  unchanged. A callback must return the same operation struct type it received;
  returning another shape is reported as `{:error, {:invalid_layer_return, ...}}`.
  """
  def run(context, phase) when is_atom(phase) do
    context.layers
    |> order_for_phase(phase)
    |> Enum.reduce_while({:ok, context}, fn layer_spec, {:ok, context} ->
      {module, layer_opts} = normalize_spec!(layer_spec)

      if Code.ensure_loaded?(module) and function_exported?(module, phase, 2) do
        case apply(module, phase, [context, layer_opts]) do
          {:ok, next_context} ->
            if same_context?(context, next_context) do
              {:cont, {:ok, next_context}}
            else
              {:halt, {:error, {:invalid_layer_return, module, phase, next_context}}}
            end

          {:error, _reason} = error ->
            {:halt, error}

          other ->
            {:halt, {:error, {:invalid_layer_return, module, phase, other}}}
        end
      else
        {:cont, {:ok, context}}
      end
    end)
  end

  @doc "Normalize a configured layer or list of layers into a flat list."
  def normalize(nil), do: []
  def normalize([]), do: []
  def normalize(module) when is_atom(module), do: [module]
  def normalize({module, opts}) when is_atom(module) and is_list(opts), do: [{module, opts}]
  def normalize(layers) when is_list(layers), do: layers

  @doc """
  Restrict and order runtime layers according to persisted metadata.

  On reads, persisted layer metadata is the source of truth for which layers
  touched the blob. Runtime configuration supplies the modules and secrets for
  those keys. A persisted key with no configured runtime layer returns a
  structured missing-layer error.
  """
  def order_by_metadata(layers, []), do: {:ok, layers}
  def order_by_metadata(layers, nil), do: {:ok, layers}

  def order_by_metadata(layers, metadata_entries) when is_list(metadata_entries) do
    with {:ok, by_layer_metadata_key} <- index_by_layer_metadata_key(layers) do
      metadata_entries
      |> Enum.reduce_while([], fn entry, ordered ->
        metadata_key = layer_metadata_key(entry)

        case Map.fetch(by_layer_metadata_key, metadata_key) do
          {:ok, layer} -> {:cont, [layer | ordered]}
          :error -> {:halt, {:error, {:missing_blob_io_layer, metadata_key}}}
        end
      end)
      |> case do
        {:error, _reason} = error -> error
        ordered -> {:ok, Enum.reverse(ordered)}
      end
    end
  end

  # Index runtime layers by metadata key, failing closed on a duplicate.
  # The old `Map.new/2` silently kept the last layer for a colliding key, which
  # dropped one layer from the read index while both still wrote metadata — for
  # encryption that means a wrong/failed decrypt. Every read path (DSL config and
  # explicit per-call `:layers` handoffs) flows through here, so this guard also
  # protects the handoff paths the compile-time verifier cannot see.
  defp index_by_layer_metadata_key(layers) do
    Enum.reduce_while(layers, {:ok, %{}}, fn layer, {:ok, acc} ->
      key = Layer.layer_metadata_key(layer)

      if Map.has_key?(acc, key) do
        {:halt, {:error, {:duplicate_blob_io_layer_key, key}}}
      else
        {:cont, {:ok, Map.put(acc, key, layer)}}
      end
    end)
  end

  defp order_for_phase(layers, :read), do: Enum.reverse(layers)
  defp order_for_phase(layers, _phase), do: layers

  defp normalize_spec!(module) when is_atom(module), do: {module, []}
  defp normalize_spec!({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}

  defp same_context?(context, next_context), do: context.__struct__ == next_context.__struct__

  defp layer_metadata_key(%{"layer_metadata_key" => layer_metadata_key}), do: layer_metadata_key

  defp layer_metadata_key(%{layer_metadata_key: layer_metadata_key}),
    do: to_string(layer_metadata_key)
end
