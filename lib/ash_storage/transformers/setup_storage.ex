defmodule AshStorage.Transformers.SetupStorage do
  @moduledoc false
  use Spark.Dsl.Transformer

  require Ash.Expr

  @before_transformers [
    Ash.Resource.Transformers.DefaultAccept,
    Ash.Resource.Transformers.SetTypes
  ]

  def before?(transformer) when transformer in @before_transformers, do: true
  def before?(_), do: false

  def transform(dsl_state) do
    all_entities = Spark.Dsl.Extension.get_entities(dsl_state, [:storage])

    attachments =
      Enum.filter(all_entities, &match?(%AshStorage.AttachmentDefinition{}, &1))

    attachment_resource = Spark.Dsl.Extension.get_opt(dsl_state, [:storage], :attachment_resource)

    with {:ok, key} <- record_key(dsl_state, attachments) do
      dsl_state
      |> maybe_add_dependent_change(attachments)
      |> add_relationships(attachments, attachment_resource, key)
      |> add_url_calculations(attachments)
      |> add_attachment_actions(attachments)
    end
  end

  # Attachment rows hold one value that identifies their host record, so a host
  # needs exactly one primary key attribute
  defp record_key(_dsl_state, []), do: {:ok, nil}

  defp record_key(dsl_state, _attachments) do
    case dsl_state
         |> Spark.Dsl.Extension.get_entities([:attributes])
         |> Enum.filter(& &1.primary_key?)
         |> Enum.map(& &1.name) do
      [key] ->
        {:ok, key}

      keys ->
        resource = Spark.Dsl.Extension.get_persisted(dsl_state, :module)

        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:storage],
           message: """
           #{inspect(resource)} declares attachments, and AshStorage identifies the \
           record an attachment belongs to by a single primary key attribute. \
           The resource's primary key is #{describe_keys(keys)}.
           """
         )}
    end
  end

  defp describe_keys([]), do: "empty"
  defp describe_keys(keys), do: "made of " <> Enum.map_join(keys, ", ", &inspect/1)

  defp maybe_add_dependent_change(dsl_state, attachments) do
    has_dependent? =
      Enum.any?(attachments, fn att ->
        att.dependent in [:purge, :detach]
      end)

    if has_dependent? do
      Ash.Resource.Builder.add_change(
        dsl_state,
        AshStorage.Changes.HandleDependentAttachments,
        on: :destroy
      )
    else
      {:ok, dsl_state}
    end
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_relationships({:ok, dsl_state}, attachments, attachment_resource, key) do
    belongs_to_resources =
      Spark.Dsl.Extension.get_entities(attachment_resource, [:attachment])

    resource = Spark.Dsl.Extension.get_persisted(dsl_state, :module)

    parent_rel =
      Enum.find(belongs_to_resources, fn bt ->
        bt.resource == resource
      end)

    destination_attribute =
      if parent_rel do
        :"#{parent_rel.name}_id"
      else
        :record_id
      end

    Enum.reduce(attachments, {:ok, dsl_state}, fn attachment_def, {:ok, dsl_state} ->
      rel_type =
        case attachment_def.type do
          :one -> :has_one
          :many -> :has_many
        end

      opts =
        [
          source_attribute: key,
          destination_attribute: destination_attribute,
          validate_destination_attribute?: not is_nil(parent_rel),
          filters: relationship_filters(dsl_state, attachment_def, parent_rel),
          public?: true
        ]

      opts =
        if attachment_def.sort do
          Keyword.put(opts, :sort, attachment_def.sort)
        else
          opts
        end

      Ash.Resource.Builder.add_relationship(
        dsl_state,
        rel_type,
        attachment_def.name,
        attachment_resource,
        opts
      )
    end)
  end

  defp add_relationships({:error, error}, _, _, _), do: {:error, error}

  # A polymorphic attachment resource is shared by every host resource that names
  # it, so its relationship has to match the host's record type as well as the
  # attachment name. With `belongs_to_resource` the foreign key already does that.
  defp relationship_filters(dsl_state, attachment_def, parent_rel) do
    name_filter = %Ash.Resource.Dsl.Filter{
      filter: Ash.Expr.expr(name == ^to_string(attachment_def.name))
    }

    if parent_rel do
      [name_filter]
    else
      record_type = AshStorage.Info.record_type(dsl_state)

      [
        name_filter,
        %Ash.Resource.Dsl.Filter{filter: Ash.Expr.expr(record_type == ^record_type)}
      ]
    end
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_url_calculations({:ok, dsl_state}, attachments) do
    resource = Spark.Dsl.Extension.get_persisted(dsl_state, :module)

    Enum.reduce(attachments, {:ok, dsl_state}, fn attachment_def, {:ok, dsl_state} ->
      with {:ok, dsl_state} <- add_base_url_calculation(dsl_state, attachment_def, resource) do
        add_variant_url_calculations(dsl_state, attachment_def, resource)
      end
    end)
  end

  defp add_url_calculations({:error, error}, _), do: {:error, error}

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_base_url_calculation(dsl_state, attachment_def, resource) do
    case attachment_def.type do
      :one ->
        Ash.Resource.Builder.add_calculation(
          dsl_state,
          :"#{attachment_def.name}_url",
          :string,
          {AshStorage.Calculations.AttachmentUrl,
           attachment_name: attachment_def.name, resource: resource},
          public?: true,
          filterable?: false,
          sortable?: false
        )

      :many ->
        Ash.Resource.Builder.add_calculation(
          dsl_state,
          :"#{attachment_def.name}_urls",
          {:array, :string},
          {AshStorage.Calculations.AttachmentUrls,
           attachment_name: attachment_def.name, resource: resource},
          public?: true,
          filterable?: false,
          sortable?: false
        )
    end
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_variant_url_calculations(dsl_state, attachment_def, resource) do
    variants = attachment_def.variants || []

    Enum.reduce(variants, {:ok, dsl_state}, fn variant_def, {:ok, dsl_state} ->
      case attachment_def.type do
        :one ->
          Ash.Resource.Builder.add_calculation(
            dsl_state,
            :"#{attachment_def.name}_#{variant_def.name}_url",
            :string,
            {AshStorage.Calculations.VariantUrl,
             attachment_name: attachment_def.name,
             variant_name: variant_def.name,
             resource: resource},
            public?: true,
            filterable?: false,
            sortable?: false
          )

        :many ->
          Ash.Resource.Builder.add_calculation(
            dsl_state,
            :"#{attachment_def.name}_#{variant_def.name}_urls",
            {:array, :string},
            {AshStorage.Calculations.VariantUrls,
             attachment_name: attachment_def.name,
             variant_name: variant_def.name,
             resource: resource},
            public?: true,
            filterable?: false,
            sortable?: false
          )
      end
    end)
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_attachment_actions({:ok, dsl_state}, attachments) do
    Enum.reduce(attachments, {:ok, dsl_state}, fn attachment_def, {:ok, dsl_state} ->
      name = attachment_def.name

      with {:ok, dsl_state} <- add_attach_action(dsl_state, name),
           {:ok, dsl_state} <- add_detach_action(dsl_state, name) do
        add_purge_action(dsl_state, name)
      end
    end)
  end

  defp add_attachment_actions({:error, error}, _), do: {:error, error}

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_attach_action(dsl_state, name) do
    {:ok, io_arg} =
      Ash.Resource.Builder.build_action_argument(:io, :term, allow_nil?: false)

    {:ok, filename_arg} =
      Ash.Resource.Builder.build_action_argument(:filename, :string, allow_nil?: false)

    {:ok, content_type_arg} =
      Ash.Resource.Builder.build_action_argument(:content_type, :string,
        default: "application/octet-stream"
      )

    {:ok, metadata_arg} =
      Ash.Resource.Builder.build_action_argument(:metadata, :map, default: %{})

    {:ok, change} =
      Ash.Resource.Builder.build_action_change({AshStorage.Changes.Attach, attachment_name: name})

    Ash.Resource.Builder.add_action(dsl_state, :update, :"attach_#{name}",
      accept: [],
      require_atomic?: false,
      arguments: [io_arg, filename_arg, content_type_arg, metadata_arg],
      changes: [change]
    )
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_detach_action(dsl_state, name) do
    {:ok, blob_id_arg} =
      Ash.Resource.Builder.build_action_argument(:blob_id, :string)

    {:ok, all_arg} =
      Ash.Resource.Builder.build_action_argument(:all, :boolean, default: false)

    {:ok, change} =
      Ash.Resource.Builder.build_action_change({AshStorage.Changes.Detach, attachment_name: name})

    Ash.Resource.Builder.add_action(dsl_state, :update, :"detach_#{name}",
      accept: [],
      require_atomic?: false,
      arguments: [blob_id_arg, all_arg],
      changes: [change]
    )
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_purge_action(dsl_state, name) do
    {:ok, blob_id_arg} =
      Ash.Resource.Builder.build_action_argument(:blob_id, :string)

    {:ok, all_arg} =
      Ash.Resource.Builder.build_action_argument(:all, :boolean, default: false)

    {:ok, change} =
      Ash.Resource.Builder.build_action_change({AshStorage.Changes.Purge, attachment_name: name})

    Ash.Resource.Builder.add_action(dsl_state, :update, :"purge_#{name}",
      accept: [],
      require_atomic?: false,
      arguments: [blob_id_arg, all_arg],
      changes: [change]
    )
  end
end
