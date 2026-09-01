defmodule AshStorage.AnalyzerMetadata do
  @moduledoc false

  alias AshStorage.Info

  def source(resource, attachment_def) do
    %{
      "resource" => to_string(resource),
      "attachment" => to_string(attachment_def.name)
    }
  end

  def fetch_source(analyzer_entry) when is_map(analyzer_entry) do
    case map_get(analyzer_entry, :source) do
      nil -> :missing
      source -> decode_source(source)
    end
  end

  def fetch_source(_analyzer_entry), do: :missing

  defp decode_source(source) when is_map(source) do
    with {:ok, resource_name} <- required_source_string(source, :resource),
         {:ok, attachment_name} <- required_source_string(source, :attachment),
         {:ok, resource} <- existing_atom(resource_name),
         {:ok, attachment} <- existing_atom(attachment_name),
         {:ok, attachment_def} <- Info.attachment(resource, attachment) do
      {:ok, resource, attachment_def}
    else
      {:error, reason} -> {:error, {:invalid_analyzer_source, reason}}
      :error -> {:error, {:invalid_analyzer_source, :unknown_attachment}}
    end
  end

  defp decode_source(_source), do: {:error, {:invalid_analyzer_source, :not_a_map}}

  defp required_source_string(source, key) do
    case map_get(source, key) do
      value when is_binary(value) -> {:ok, value}
      value when is_atom(value) -> {:ok, to_string(value)}
      _ -> {:error, {:missing_source_key, key}}
    end
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, value}}
  end

  defp map_get(map, key) do
    case Map.fetch(map, to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end
end
