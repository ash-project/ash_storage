defmodule AshStorage.BlobTest do
  use ExUnit.Case, async: true

  describe "generate_key/0" do
    test "returns a 56-character hex string" do
      key = AshStorage.Blob.generate_key()
      assert String.length(key) == 56
      assert key =~ ~r/\A[0-9a-f]{56}\z/
    end

    test "generates unique keys" do
      keys = for _ <- 1..100, do: AshStorage.Blob.generate_key()
      assert length(Enum.uniq(keys)) == 100
    end
  end
end
