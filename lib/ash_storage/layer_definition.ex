defmodule AshStorage.LayerDefinition do
  @moduledoc "Represents a configured layer on a resource or attachment."

  defstruct [
    :module,
    :opts,
    :metadata_key,
    :__spark_metadata__
  ]

  @schema [
    module: [
      type: {:or, [:atom, {:tuple, [:atom, :keyword_list]}]},
      required: true,
      doc:
        "The layer module, or a `{module, opts}` tuple where opts are passed to the layer callbacks."
    ],
    metadata_key: [
      type: :string,
      required: false,
      doc: "Stable identifier for this configured layer instance in persisted blob metadata."
    ]
  ]

  def schema, do: @schema

  @doc false
  def transform(%__MODULE__{} = definition) do
    {module, opts} = split_module(definition.module)

    with {:ok, opts} <- normalize_dsl_metadata_key(opts, definition.metadata_key) do
      {:ok, %{definition | module: module, opts: opts}}
    end
  end

  @doc false
  def normalize_spec(%__MODULE__{} = definition), do: runtime_spec(definition)

  def normalize_spec({module, opts}) when is_atom(module) and is_list(opts) do
    {module, normalize_opts(opts)}
  end

  def normalize_spec(module) when is_atom(module), do: module

  def normalize_spec(other), do: other

  @doc false
  def runtime_spec(%__MODULE__{module: module, opts: opts}) do
    case opts || [] do
      [] -> module
      opts -> {module, opts}
    end
  end

  defp normalize_dsl_metadata_key(opts, metadata_key) do
    cond do
      Keyword.has_key?(opts, :layer_metadata_key) ->
        {:error, "use the metadata_key DSL field instead of :layer_metadata_key for a layer"}

      Keyword.has_key?(opts, :metadata_key) ->
        {:error, "use the metadata_key DSL field instead of a :metadata_key layer option"}

      is_nil(metadata_key) ->
        {:ok, opts}

      true ->
        {:ok, Keyword.put(opts, :layer_metadata_key, metadata_key)}
    end
  end

  defp normalize_opts(opts) do
    opts
    |> maybe_rename_metadata_key()
  end

  defp maybe_rename_metadata_key(opts) do
    case Keyword.pop(opts, :metadata_key) do
      {nil, opts} -> opts
      {metadata_key, opts} -> Keyword.put_new(opts, :layer_metadata_key, metadata_key)
    end
  end

  defp split_module({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp split_module(module) when is_atom(module), do: {module, []}
end
