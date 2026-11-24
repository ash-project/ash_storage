defmodule AshStorage.Pipeline.Owner do
  @moduledoc false
  # How an attachment row points at its host record. A polymorphic attachment
  # resource stores the record's type and id; one with `belongs_to_resource`
  # for the host stores the id in that relationship's foreign key. Nothing else
  # in the pipeline builds either shape.

  alias AshStorage.Pipeline.Target

  defstruct [:record_type, :foreign_key]

  @type t :: %__MODULE__{record_type: String.t() | nil, foreign_key: atom() | nil}

  @doc "How rows of `attachment_resource` identify a record of `resource`."
  @spec new(Ash.Resource.t(), Ash.Resource.t()) :: t()
  # sobelow_skip ["DOS.BinToAtom"]
  def new(resource, attachment_resource) do
    attachment_resource
    |> Spark.Dsl.Extension.get_entities([:attachment])
    |> Enum.find(&(&1.resource == resource))
    |> case do
      nil -> %__MODULE__{record_type: AshStorage.Info.record_type(resource)}
      parent -> %__MODULE__{foreign_key: :"#{parent.name}_id"}
    end
  end

  @doc """
  The attributes that tie an attachment row to `record` under the target's
  attachment name: the filter for its rows, and the params of a new one.
  """
  @spec keys(Target.t(), struct()) :: keyword()
  def keys(%Target{owner: owner, attachment: attachment}, record) do
    name = to_string(attachment.name)

    case owner do
      %__MODULE__{foreign_key: nil, record_type: record_type} ->
        [name: name, record_type: record_type, record_id: id(record)]

      %__MODULE__{foreign_key: foreign_key} ->
        [{:name, name}, {foreign_key, id(record)}]
    end
  end

  @doc "Where an analyzer writes its `write_attributes` back to: the host record."
  @spec write_target(Target.t(), struct()) :: map()
  def write_target(%Target{resource: resource}, record) do
    %{"resource" => to_string(resource), "id" => id(record)}
  end

  defp id(record), do: Map.get(record, :id) |> to_string()
end
