defmodule AshStorage.Pipeline.Scope do
  @moduledoc false
  # Who an internal read or write runs as. Every Ash call the pipeline makes
  # takes its options from `to_opts/2`, so the caller's tenant, actor and
  # `authorize?` cannot be dropped on the way.

  defstruct [:actor, :tenant, :authorize?, :tracer, :context]

  @type t :: %__MODULE__{
          actor: term(),
          tenant: term(),
          authorize?: boolean() | nil,
          tracer: module() | [module()] | nil,
          context: map() | nil
        }

  @doc "The scope of a change, built inside a hook from that hook's changeset."
  @spec from_change(Ash.Changeset.t(), Ash.Resource.Change.Context.t() | map()) :: t()
  def from_change(changeset, context) do
    opts = Ash.Context.to_opts(context)
    %{from_opts(opts) | tenant: changeset.tenant || opts[:tenant]}
  end

  @doc "The scope of a calculation, such as an on-demand variant URL."
  @spec from_calculation(map()) :: t()
  def from_calculation(context) do
    %__MODULE__{
      actor: Map.get(context, :actor),
      tenant: Map.get(context, :tenant),
      authorize?: Map.get(context, :authorize?),
      tracer: Map.get(context, :tracer)
    }
  end

  @doc "The scope of a direct call that takes Ash options."
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    %__MODULE__{
      actor: opts[:actor],
      tenant: opts[:tenant],
      authorize?: opts[:authorize?],
      tracer: opts[:tracer],
      context: opts[:context]
    }
  end

  @doc "Sets the tenant when the scope has none."
  @spec put_new_tenant(t(), term()) :: t()
  def put_new_tenant(%__MODULE__{tenant: nil} = scope, tenant), do: %{scope | tenant: tenant}
  def put_new_tenant(%__MODULE__{} = scope, _tenant), do: scope

  @doc """
  Options for `Ash.read/2`, `Ash.create/3` and the like. `actor` and `tenant`
  are always present; the other fields only when set.
  """
  @spec to_opts(t(), keyword()) :: keyword()
  def to_opts(%__MODULE__{} = scope, extra \\ []) do
    [actor: scope.actor, tenant: scope.tenant]
    |> put_set(:authorize?, scope.authorize?)
    |> put_set(:tracer, scope.tracer)
    |> put_set(:context, scope.context)
    |> Keyword.merge(extra)
  end

  defp put_set(opts, _key, nil), do: opts
  defp put_set(opts, key, value), do: opts ++ [{key, value}]
end
