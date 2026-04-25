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

    belongs_to_resources =
      Spark.Dsl.Extension.get_entities(dsl_state, [:attachment])

    dsl_state
    |> add_attributes(belongs_to_resources)
    |> add_relationships(blob_resource, belongs_to_resources)
    |> add_calculations(belongs_to_resources)
    |> add_actions(belongs_to_resources)
  end

  defp add_attributes(dsl_state, belongs_to_resources) do
    base_attrs = [
      {:name, :string, allow_nil?: false, public?: true, writable?: true}
    ]

    polymorphic_attrs =
      if belongs_to_resources == [] do
        [
          {:record_type, :string, allow_nil?: false, public?: true, writable?: true},
          {:record_id, :string, allow_nil?: false, public?: true, writable?: true}
        ]
      else
        []
      end

    Enum.reduce(base_attrs ++ polymorphic_attrs, {:ok, dsl_state}, fn {name, type, opts},
                                                                      {:ok, dsl_state} ->
      Ash.Resource.Builder.add_new_attribute(dsl_state, name, type, opts)
    end)
  end

  defp add_relationships({:ok, dsl_state}, blob_resource, belongs_to_resources) do
    with {:ok, dsl_state} <-
           Ash.Resource.Builder.add_relationship(
             dsl_state,
             :belongs_to,
             :blob,
             blob_resource,
             allow_nil?: false,
             public?: true,
             attribute_writable?: true
           ) do
      Enum.reduce(belongs_to_resources, {:ok, dsl_state}, fn %{
                                                               name: name,
                                                               resource: resource,
                                                               attribute_type: attribute_type
                                                             },
                                                             {:ok, dsl_state} ->
        opts =
          if attribute_type do
            [
              allow_nil?: true,
              public?: true,
              attribute_writable?: true,
              attribute_type: attribute_type
            ]
          else
            [allow_nil?: true, public?: true, attribute_writable?: true]
          end

        Ash.Resource.Builder.add_relationship(dsl_state, :belongs_to, name, resource, opts)
      end)
    end
  end

  defp add_relationships({:error, error}, _, _), do: {:error, error}

  defp add_calculations({:ok, dsl_state}, belongs_to_resources) do
    parent_resources =
      Enum.map(belongs_to_resources, fn %{name: name, resource: resource} ->
        {name, resource}
      end)

    Ash.Resource.Builder.add_calculation(
      dsl_state,
      :url,
      :string,
      {AshStorage.Calculations.Url, parent_resources: parent_resources},
      public?: true,
      filterable?: false,
      sortable?: false
    )
  end

  defp add_calculations({:error, error}, _), do: {:error, error}

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_actions({:ok, dsl_state}, belongs_to_resources) do
    accept =
      if belongs_to_resources == [] do
        [:name, :record_type, :record_id, :blob_id]
      else
        belongs_to_attrs = Enum.map(belongs_to_resources, &:"#{&1.name}_id")
        [:name, :blob_id] ++ belongs_to_attrs
      end

    with {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :create, :create,
             primary?: true,
             accept: accept
           ),
         {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :read, :read, primary?: true) do
      Ash.Resource.Builder.add_action(dsl_state, :destroy, :destroy, primary?: true)
    end
  end

  defp add_actions({:error, error}, _), do: {:error, error}
end
