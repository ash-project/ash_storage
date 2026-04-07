defmodule Mix.Tasks.AshStorage.InstallTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  test "creates domain, blob, and attachment resources" do
    test_project()
    |> Igniter.compose_task("ash_storage.install", [])
    |> assert_creates("lib/test/storage.ex")
    |> assert_creates("lib/test/storage/blob.ex")
    |> assert_creates("lib/test/storage/attachment.ex")
  end
end
