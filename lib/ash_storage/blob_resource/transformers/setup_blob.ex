defmodule AshStorage.BlobResource.Transformers.SetupBlob do
  @moduledoc false
  use Spark.Dsl.Transformer

  @before_transformers [
    Ash.Resource.Transformers.DefaultAccept,
    Ash.Resource.Transformers.SetTypes,
    Ash.Resource.Transformers.SetRelationshipSource
  ]

  def before?(transformer) when transformer in @before_transformers, do: true

  def before?(AshOban.Transformers.SetDefaults), do: true
  def before?(AshOban.Transformers.DefineSchedulers), do: true
  def before?(AshOban.Transformers.DefineActionWorkers), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    dsl_state
    |> add_attributes()
    |> add_relationships()
    |> add_calculations()
    |> add_actions()
  end

  defp add_attributes(dsl_state) do
    attrs = [
      {:key, :string, allow_nil?: false, public?: true, writable?: true},
      {:filename, :string, allow_nil?: false, public?: true, writable?: true},
      {:content_type, :string, allow_nil?: true, public?: true, writable?: true},
      {:byte_size, :integer, allow_nil?: true, public?: true, writable?: true},
      {:checksum, :string, allow_nil?: true, public?: true, writable?: true},
      {:service_name, :atom, allow_nil?: false, public?: true, writable?: true},
      {:service_opts, :map, allow_nil?: true, public?: true, writable?: true, default: %{}},
      {:metadata, :map, allow_nil?: true, public?: true, writable?: true, default: %{}},
      {:analyzers, :map, allow_nil?: true, public?: true, writable?: true, default: %{}},
      {:pending_purge, :boolean,
       allow_nil?: false, public?: true, writable?: true, default: false},
      {:pending_analyzers, :boolean,
       allow_nil?: false, public?: true, writable?: true, default: false},
      {:pending_variants, :boolean,
       allow_nil?: false, public?: true, writable?: true, default: false},
      {:variant_of_blob_id, :uuid, allow_nil?: true, public?: true, writable?: true},
      {:variant_name, :string, allow_nil?: true, public?: true, writable?: true},
      {:variant_digest, :string, allow_nil?: true, public?: true, writable?: true}
    ]

    Enum.reduce(attrs, {:ok, dsl_state}, fn {name, type, opts}, {:ok, dsl_state} ->
      Ash.Resource.Builder.add_new_attribute(dsl_state, name, type, opts)
    end)
  end

  defp add_relationships({:ok, dsl_state}) do
    blob_resource = Spark.Dsl.Extension.get_persisted(dsl_state, :module)

    with {:ok, dsl_state} <-
           Ash.Resource.Builder.add_relationship(
             dsl_state,
             :belongs_to,
             :source_blob,
             blob_resource,
             source_attribute: :variant_of_blob_id,
             define_attribute?: false,
             public?: true
           ) do
      Ash.Resource.Builder.add_relationship(
        dsl_state,
        :has_many,
        :variants,
        blob_resource,
        destination_attribute: :variant_of_blob_id,
        public?: true
      )
    end
  end

  defp add_relationships({:error, error}), do: {:error, error}

  defp add_calculations({:ok, dsl_state}) do
    Ash.Resource.Builder.add_calculation(
      dsl_state,
      :parsed_service_opts,
      :term,
      AshStorage.BlobResource.Calculations.ParsedServiceOpts,
      public?: false,
      filterable?: false,
      sortable?: false
    )
  end

  defp add_calculations({:error, error}), do: {:error, error}

  defp add_actions({:ok, dsl_state}) do
    with {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :create, :create,
             primary?: true,
             accept: [
               :key,
               :filename,
               :content_type,
               :byte_size,
               :checksum,
               :service_name,
               :service_opts,
               :metadata,
               :analyzers
             ]
           ),
         {:ok, pagination} <-
           Ash.Resource.Builder.build_pagination(keyset?: true),
         {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :read, :read,
             primary?: true,
             pagination: pagination
           ),
         {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :destroy, :destroy, primary?: true),
         {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :update, :update_metadata,
             accept: [:metadata, :analyzers, :pending_analyzers, :pending_variants]
           ),
         {:ok, dsl_state} <-
           Ash.Resource.Builder.add_action(dsl_state, :update, :mark_for_purge,
             accept: [:pending_purge]
           ),
         {:ok, dsl_state} <- add_complete_analysis_action(dsl_state),
         {:ok, dsl_state} <- add_run_pending_analyzers_action(dsl_state),
         {:ok, dsl_state} <- add_create_variant_action(dsl_state),
         {:ok, dsl_state} <- add_run_pending_variants_action(dsl_state) do
      {:ok, purge_change} =
        Ash.Resource.Builder.build_action_change(AshStorage.BlobResource.Changes.PurgeFile)

      Ash.Resource.Builder.add_action(dsl_state, :destroy, :purge_blob, changes: [purge_change])
    end
  end

  defp add_actions({:error, error}), do: {:error, error}

  defp add_complete_analysis_action(dsl_state) do
    {:ok, analyzer_key_arg} =
      Ash.Resource.Builder.build_action_argument(:analyzer_key, :string, allow_nil?: false)

    {:ok, status_arg} =
      Ash.Resource.Builder.build_action_argument(:status, :string, allow_nil?: false)

    {:ok, metadata_to_merge_arg} =
      Ash.Resource.Builder.build_action_argument(:metadata_to_merge, :map, default: %{})

    {:ok, complete_change} =
      Ash.Resource.Builder.build_action_change(AshStorage.BlobResource.Changes.CompleteAnalysis)

    Ash.Resource.Builder.add_action(dsl_state, :update, :complete_analysis,
      accept: [],
      arguments: [analyzer_key_arg, status_arg, metadata_to_merge_arg],
      changes: [complete_change]
    )
  end

  defp add_create_variant_action(dsl_state) do
    Ash.Resource.Builder.add_action(dsl_state, :create, :create_variant,
      accept: [
        :key,
        :filename,
        :content_type,
        :byte_size,
        :checksum,
        :service_name,
        :service_opts,
        :metadata,
        :variant_of_blob_id,
        :variant_name,
        :variant_digest
      ]
    )
  end

  defp add_run_pending_variants_action(dsl_state) do
    {:ok, change} =
      Ash.Resource.Builder.build_action_change(AshStorage.BlobResource.Changes.RunPendingVariants)

    Ash.Resource.Builder.add_action(dsl_state, :update, :run_pending_variants,
      accept: [],
      require_atomic?: false,
      changes: [change]
    )
  end

  defp add_run_pending_analyzers_action(dsl_state) do
    {:ok, change} =
      Ash.Resource.Builder.build_action_change(
        AshStorage.BlobResource.Changes.RunPendingAnalyzers
      )

    Ash.Resource.Builder.add_action(dsl_state, :update, :run_pending_analyzers,
      accept: [],
      require_atomic?: false,
      changes: [change]
    )
  end
end
