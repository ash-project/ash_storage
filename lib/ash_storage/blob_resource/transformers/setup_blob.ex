defmodule AshStorage.BlobResource.Transformers.SetupBlob do
  @moduledoc false
  use Spark.Dsl.Transformer

  @before_transformers [
    Ash.Resource.Transformers.DefaultAccept,
    Ash.Resource.Transformers.SetTypes
  ]

  def before?(transformer) when transformer in @before_transformers, do: true
  def before?(_), do: false

  def transform(dsl_state) do
    dsl_state
    |> add_attributes()
    |> add_actions()
  end

  defp add_attributes(dsl_state) do
    attrs = [
      {:key, :string, allow_nil?: false, public?: true, writable?: true},
      {:filename, :string, allow_nil?: false, public?: true, writable?: true},
      {:content_type, :string, allow_nil?: true, public?: true, writable?: true},
      {:byte_size, :integer, allow_nil?: false, public?: true, writable?: true},
      {:checksum, :string, allow_nil?: false, public?: true, writable?: true},
      {:service_name, :atom, allow_nil?: false, public?: true, writable?: true},
      {:metadata, :map, allow_nil?: true, public?: true, writable?: true, default: %{}}
    ]

    Enum.reduce(attrs, {:ok, dsl_state}, fn {name, type, opts}, {:ok, dsl_state} ->
      Ash.Resource.Builder.add_new_attribute(dsl_state, name, type, opts)
    end)
  end

  defp add_actions({:ok, dsl_state}) do
    with {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :create, :create,
             accept: [
               :key,
               :filename,
               :content_type,
               :byte_size,
               :checksum,
               :service_name,
               :metadata
             ]
           ),
         {:ok, dsl_state} <- Ash.Resource.Builder.add_action(dsl_state, :read, :read),
         {:ok, dsl_state} <- Ash.Resource.Builder.add_action(dsl_state, :destroy, :destroy) do
      Ash.Resource.Builder.add_action(dsl_state, :update, :update_metadata, accept: [:metadata])
    end
  end

  defp add_actions({:error, error}), do: {:error, error}
end
