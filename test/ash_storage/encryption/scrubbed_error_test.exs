defmodule AshStorage.Encryption.ScrubbedErrorTest do
  use ExUnit.Case, async: true

  alias AshStorage.Encryption.ScrubbedError

  describe "describe_term/1 (returned key-manager / vault error scrubbing)" do
    test "reduces a raw binary (e.g. a DEK) to its size, not its bytes" do
      dek = :crypto.strong_rand_bytes(32)
      assert ScrubbedError.describe_term(dek) == {:binary, 32}
      refute dek_bytes_present?(ScrubbedError.describe_term(dek), dek)
    end

    test "reduces a map (e.g. a wrapped DEK) to its size" do
      assert ScrubbedError.describe_term(%{"a" => 1, "b" => 2}) == {:map, 2}
    end

    test "recurses tuples so a near-miss return shape is reported without secrets" do
      dek = :crypto.strong_rand_bytes(32)
      # A key manager returning {:ok, dek, meta} instead of {:ok, dek} would
      # otherwise embed the raw DEK in the error tuple.
      described = ScrubbedError.describe_term({:ok, dek, %{"kid" => "k1"}})
      assert described == {:tuple, [:ok, {:binary, 32}, {:map, 1}]}
      refute dek_bytes_present?(described, dek)
    end

    test "retains non-secret structural hints (atoms, integers)" do
      assert ScrubbedError.describe_term(:some_reason) == :some_reason
      assert ScrubbedError.describe_term(42) == 42
    end
  end

  defp dek_bytes_present?(described, dek) do
    described |> inspect() |> String.contains?(Base.encode16(dek))
  end
end
