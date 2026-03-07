defmodule AshStorage.Resource.Transformers.SetupStorage do
  @moduledoc false
  use Spark.Dsl.Transformer

  require Ash.Expr

  def transform(dsl_state) do
    attachments = Spark.Dsl.Extension.get_entities(dsl_state, [:storage])
    attachment_resource = Spark.Dsl.Extension.get_opt(dsl_state, [:storage], :attachment_resource)

    dsl_state
    |> maybe_add_dependent_change(attachments)
    |> add_relationships(attachments, attachment_resource)
    |> add_url_calculations(attachments)
  end

  defp maybe_add_dependent_change(dsl_state, attachments) do
    has_dependent? =
      Enum.any?(attachments, fn att ->
        att.dependent in [:purge, :detach]
      end)

    if has_dependent? do
      Ash.Resource.Builder.add_change(
        dsl_state,
        AshStorage.Resource.Changes.HandleDependentAttachments,
        on: :destroy
      )
    else
      {:ok, dsl_state}
    end
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_relationships({:ok, dsl_state}, attachments, attachment_resource) do
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

      name_filter = %Ash.Resource.Dsl.Filter{
        filter: Ash.Expr.expr(name == ^to_string(attachment_def.name))
      }

      Ash.Resource.Builder.add_relationship(
        dsl_state,
        rel_type,
        attachment_def.name,
        attachment_resource,
        destination_attribute: destination_attribute,
        filters: [name_filter],
        public?: true
      )
    end)
  end

  defp add_relationships({:error, error}, _, _), do: {:error, error}

  # sobelow_skip ["DOS.BinToAtom"]
  defp add_url_calculations({:ok, dsl_state}, attachments) do
    resource = Spark.Dsl.Extension.get_persisted(dsl_state, :module)

    Enum.reduce(attachments, {:ok, dsl_state}, fn attachment_def, {:ok, dsl_state} ->
      calc_name = :"#{attachment_def.name}_urls"

      case attachment_def.type do
        :one ->
          Ash.Resource.Builder.add_calculation(
            dsl_state,
            :"#{attachment_def.name}_url",
            :string,
            {AshStorage.Resource.Calculations.AttachmentUrl,
             attachment_name: attachment_def.name, resource: resource},
            public?: true,
            filterable?: false,
            sortable?: false
          )

        :many ->
          Ash.Resource.Builder.add_calculation(
            dsl_state,
            calc_name,
            {:array, :string},
            {AshStorage.Resource.Calculations.AttachmentUrls,
             attachment_name: attachment_def.name, resource: resource},
            public?: true,
            filterable?: false,
            sortable?: false
          )
      end
    end)
  end

  defp add_url_calculations({:error, error}, _), do: {:error, error}
end
