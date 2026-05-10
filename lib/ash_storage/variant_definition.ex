defmodule AshStorage.VariantDefinition do
  @moduledoc "Represents a configured variant on an attachment"
  defstruct [
    :name,
    :module,
    :generate,
    :group,
    :order,
    :__spark_metadata__
  ]

  @schema [
    name: [
      type: :atom,
      doc: "Unique name for this variant (e.g. `:thumbnail`, `:hero`).",
      required: true
    ],
    module: [
      type: {:or, [:atom, {:tuple, [:atom, :keyword_list]}]},
      doc:
        "The variant module (implementing `AshStorage.Variant`), or a `{module, opts}` tuple where opts are passed to `transform/3`.",
      required: true
    ],
    generate: [
      type: {:one_of, [:on_demand, :eager, :oban]},
      doc:
        "When to generate this variant. `:on_demand` generates on first URL request, `:eager` during attach, `:oban` via background job.",
      default: :on_demand
    ],
    group: [
      type: {:or, [:atom, nil]},
      default: nil,
      doc: """
      Co-locates this variant with every other oban variant that shares the same group. \
      All variants in a group run serially in a single Oban job, sharing one download \
      and one worker process. Variants without a group run in their own jobs (the default). \
      Trade-off: variants in a group share a retry — if any one fails, Oban retries the \
      whole group. Only meaningful with `generate: :oban`.
      """
    ],
    order: [
      type: :integer,
      default: 0,
      doc: """
      Dispatch tier. Lower runs before higher. Units (variants or groups) at the same \
      `order` run in parallel. Variants in the same group must declare the same order — \
      the verifier enforces this. Only meaningful with `generate: :oban`.
      """
    ]
  ]

  def schema, do: @schema

  @doc """
  Normalize a VariantDefinition into a `{module, opts}` tuple.
  """
  def normalize(%__MODULE__{} = defn) do
    case defn.module do
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc """
  Compute a digest of the variant definition for cache invalidation.

  Only the transform inputs (`module` + `opts`) feed the digest — `group` and
  `order` are scheduling concerns and changing them must not invalidate
  already-generated variant blobs.
  """
  def digest(%__MODULE__{} = defn) do
    {mod, opts} = normalize(defn)

    :crypto.hash(:sha256, :erlang.term_to_binary({mod, opts}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
