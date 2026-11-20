defmodule AshStorage.Test.KnownGap do
  @moduledoc false
  # Runs one cell of a behaviour matrix. A cell listed in `gaps` is expected to
  # fail, and flunks once it passes, so that fixing a gap also removes it from
  # the list.

  import ExUnit.Assertions

  def check(gaps, cell, fun) when is_map(gaps) and is_function(fun, 0) do
    case Map.fetch(gaps, cell) do
      :error ->
        fun.()

      {:ok, issue} ->
        if fails?(fun) do
          :ok
        else
          flunk("#{inspect(cell)} no longer fails (#{issue}): remove it from @gaps")
        end
    end
  end

  defp fails?(fun) do
    fun.()
    false
  catch
    _kind, _reason -> true
  end
end
