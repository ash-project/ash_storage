defmodule AshStorage.AttachmentResource.Transformers.SetupAttachment do
  @moduledoc false
  use Spark.Dsl.Transformer

  @before_transformers [
    Ash.Resource.Transformers.DefaultAccept,
    Ash.Resource.Transformers.SetTypes
  ]

  def before?(transformer) when transformer in @before_transformers, do: true
  def before?(_), do: false

  def transform(dsl_state) do
    blob_resource =
      Spark.Dsl.Extension.get_opt(dsl_state, [:attachment], :blob_resource)

    dsl_state
    |> add_attributes()
    |> add_relationships(blob_resource)
    |> add_actions()
  end

  defp add_attributes(dsl_state) do
    attrs = [
      {:name, :string, allow_nil?: false, public?: true, writable?: true},
      {:record_type, :string, allow_nil?: false, public?: true, writable?: true},
      {:record_id, :string, allow_nil?: false, public?: true, writable?: true}
    ]

    Enum.reduce(attrs, {:ok, dsl_state}, fn {name, type, opts}, {:ok, dsl_state} ->
      Ash.Resource.Builder.add_new_attribute(dsl_state, name, type, opts)
    end)
  end

  defp add_relationships({:ok, dsl_state}, blob_resource) do
    Ash.Resource.Builder.add_relationship(
      dsl_state,
      :belongs_to,
      :blob,
      blob_resource,
      allow_nil?: false,
      public?: true,
      attribute_writable?: true
    )
  end

  defp add_relationships({:error, error}, _), do: {:error, error}

  defp add_actions({:ok, dsl_state}) do
    with {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :create, :create,
             accept: [:name, :record_type, :record_id, :blob_id]
           ),
         {:ok, dsl_state} <- Ash.Resource.Builder.add_action(dsl_state, :read, :read) do
      Ash.Resource.Builder.add_action(dsl_state, :destroy, :destroy)
    end
  end

  defp add_actions({:error, error}), do: {:error, error}
end
