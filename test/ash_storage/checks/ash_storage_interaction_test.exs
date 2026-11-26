defmodule AshStorage.Checks.AshStorageInteractionTest do
  use ExUnit.Case, async: true

  alias AshStorage.Checks.AshStorageInteraction

  defp matches?(context),
    do: AshStorageInteraction.match?(nil, %{subject: %{context: context}}, [])

  test "matches a call that carries the marker" do
    assert matches?(%{private: %{ash_storage?: true}})
  end

  test "does not match without the marker" do
    refute matches?(%{})
    refute matches?(%{private: %{}})
    refute matches?(%{private: %{ash_storage?: false}})
  end

  test "does not match a shared key of the same name" do
    refute matches?(%{shared: %{ash_storage?: true}})
  end

  test "describes itself" do
    assert AshStorageInteraction.describe([]) == "AshStorage is performing this interaction"
  end
end
