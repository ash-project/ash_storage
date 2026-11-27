defmodule AshStorage.Pipeline.ScopeTest do
  use ExUnit.Case, async: true

  alias AshStorage.Pipeline.Scope

  defp changeset(tenant) do
    AshStorage.Test.Post
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(tenant)
  end

  defp change_context(fields) do
    struct(Ash.Resource.Change.Context, fields)
  end

  describe "from_change/2" do
    test "takes each value from the change context" do
      context =
        change_context(
          actor: %{id: "actor"},
          tenant: "org_1",
          authorize?: false,
          tracer: [Ash.Tracer.Simple],
          source_context: %{shared: %{locale: "en"}, private: %{}}
        )

      scope = Scope.from_change(changeset("org_1"), context)

      assert scope == %Scope{
               actor: %{id: "actor"},
               tenant: "org_1",
               authorize?: false,
               tracer: [Ash.Tracer.Simple],
               context: %{shared: %{locale: "en"}}
             }

      assert Scope.to_opts(scope) == [
               actor: %{id: "actor"},
               tenant: "org_1",
               authorize?: false,
               tracer: [Ash.Tracer.Simple],
               context: %{shared: %{locale: "en"}}
             ]
    end

    test "takes the tenant from the changeset when the context has none" do
      scope = Scope.from_change(changeset("org_2"), change_context(source_context: %{}))

      assert scope.tenant == "org_2"
    end
  end

  test "from_opts/1 reads the Ash options" do
    assert Scope.from_opts(actor: :me, tenant: "t", authorize?: true, tracer: T, context: %{}) ==
             %Scope{actor: :me, tenant: "t", authorize?: true, tracer: T, context: %{}}
  end

  describe "from_opts/1 with a scope" do
    test "takes the scope's values, and explicit options win" do
      scope = %{actor: :scoped, tenant: "t", authorize?: false}

      assert %Scope{actor: :explicit, tenant: "t", authorize?: false} =
               Scope.from_opts(scope: scope, actor: :explicit)
    end

    test "merges the scope's context with the explicit one, explicit keys winning" do
      scope = %{context: %{shared: %{x: 1, y: 1}}}

      assert Scope.from_opts(scope: scope, context: %{shared: %{y: 2}}).context ==
               %{shared: %{x: 1, y: 2}}

      assert Scope.from_opts(scope: scope).context == %{shared: %{x: 1, y: 1}}
      assert Scope.from_opts(context: %{shared: %{y: 2}}).context == %{shared: %{y: 2}}
    end

    test "keeps the scope's context when the explicit one is nil" do
      scope = %{context: %{shared: %{x: 1}}}

      assert Scope.from_opts(scope: scope, context: nil).context == %{shared: %{x: 1}}

      assert Scope.from_opts(scope: scope, context: %{shared: %{x: nil}}).context ==
               %{shared: %{x: nil}}
    end

    test "lets an explicit struct win whole instead of merging into it" do
      scope = %{context: %{shared: %{at: ~U[2026-02-02 10:00:00Z], meta: %{extra: 1}}}}
      explicit = %{shared: %{at: ~D[2026-01-01], meta: ~D[2026-03-03]}}

      assert Scope.from_opts(scope: scope, context: explicit).context == explicit
    end
  end

  test "from_calculation/1 reads the calculation context" do
    context = %Ash.Resource.Calculation.Context{actor: :me, tenant: "t", authorize?: false}

    assert %Scope{actor: :me, tenant: "t", authorize?: false} = Scope.from_calculation(context)
  end

  test "put_new_tenant/2 keeps an existing tenant" do
    assert Scope.put_new_tenant(%Scope{}, "t").tenant == "t"
    assert Scope.put_new_tenant(%Scope{tenant: "kept"}, "t").tenant == "kept"
  end

  describe "to_opts/2" do
    test "merges the extra options" do
      assert Scope.to_opts(%Scope{actor: :me}, action: :create) ==
               [actor: :me, tenant: nil, action: :create]
    end

    test "leaves out unset authorize?, tracer and context" do
      opts = Scope.to_opts(%Scope{})

      assert opts == [actor: nil, tenant: nil]
      refute Keyword.has_key?(opts, :authorize?)
    end
  end
end
