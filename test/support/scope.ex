defmodule AshStorage.Test.Scope do
  @moduledoc false
  # An application's scope struct, as passed with `scope:`. The protocol
  # implementation lives here because protocols are consolidated before test
  # files are compiled.
  defstruct [:current_user, :current_tenant]

  defimpl Ash.Scope.ToOpts do
    def get_actor(%{current_user: user}), do: {:ok, user}
    def get_tenant(%{current_tenant: tenant}), do: {:ok, tenant}
    def get_context(_scope), do: :error
    def get_tracer(_scope), do: :error
    def get_authorize?(_scope), do: :error
  end
end
