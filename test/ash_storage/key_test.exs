defmodule AshStorage.KeyTest do
  use ExUnit.Case, async: true

  alias AshStorage.Key

  doctest AshStorage.Key

  @max String.duplicate("a", 1024)

  describe "validate/1" do
    test "accepts generated keys and ordinary paths" do
      for key <- [
            AshStorage.generate_key(),
            "a",
            "org-1/covers/3f9a.png",
            "tenant_42/a/b/c/d",
            ".hidden/a..b",
            "A-Z_a.z/0-9",
            "-leading/_underscore/.dot",
            @max
          ] do
        assert Key.validate(key) == :ok, "expected #{inspect(key)} to be valid"
      end
    end

    test "rejects every shape the rules name, with the reason and the value" do
      for {key, reason} <- [
            {nil, :not_a_binary},
            {:key, :not_a_binary},
            {~c"key", :not_a_binary},
            {["a", "b"], :not_a_binary},
            {"", :empty},
            {@max <> "a", :too_long},
            {<<"a", 0xFF, "b">>, :invalid_character},
            {"a\0b", :invalid_character},
            {"a\nb", :invalid_character},
            {"a\r\nb", :invalid_character},
            {"a\tb", :invalid_character},
            {"a\x7Fb", :invalid_character},
            {"a\u0085b", :invalid_character},
            {"a\\b", :invalid_character},
            {"..\\..\\b", :invalid_character},
            {"a b", :invalid_character},
            {"a~b", :invalid_character},
            {"a%20b", :invalid_character},
            {"a?b", :invalid_character},
            {"a#b", :invalid_character},
            {"été.png", :invalid_character},
            {"日本語", :invalid_character},
            {"a\u00A0b", :invalid_character},
            {"a\n", :invalid_character},
            {"../é", :invalid_character},
            {"/a b", :invalid_character},
            {"/", :absolute},
            {"/a", :absolute},
            {"//a", :absolute},
            {"a/", :trailing_slash},
            {"a//b", :empty_segment},
            {".", :dot_segment},
            {"./a", :dot_segment},
            {"a/./b", :dot_segment},
            {"a/.", :dot_segment},
            {"..", :parent_segment},
            {"../a", :parent_segment},
            {"a/../b", :parent_segment},
            {"a/..", :parent_segment},
            {"a//../b", :parent_segment},
            {"a.", :trailing_dot},
            {"a./b", :trailing_dot},
            {".hidden/...", :trailing_dot}
          ] do
        assert Key.validate(key) == {:error, {:invalid_storage_key, reason, key}},
               "expected #{inspect(key)} to be rejected as #{inspect(reason)}"
      end
    end

    test "accepts exactly the bytes A-Z, a-z, 0-9, `.`, `_`, `-` and `/`" do
      allowed = Enum.concat([?A..?Z, ?a..?z, ?0..?9, [?., ?_, ?-, ?/]])

      for byte <- 0..255 do
        key = "a" <> <<byte>> <> "b"

        expected =
          if byte in allowed,
            do: :ok,
            else: {:error, {:invalid_storage_key, :invalid_character, key}}

        assert Key.validate(key) == expected, "byte #{byte}"
      end
    end
  end

  describe "validate_lookup/1" do
    test "accepts valid keys, and keys that were storable before the rules existed" do
      for key <- [
            "org-1/covers/3f9a.png",
            "back\\slash.png",
            "C:\\fakepath\\photo.png",
            "a//b",
            "a/./b",
            "a/",
            "a..b/...",
            <<"a", 0xFF, "b">>,
            "a\u0085b",
            "with space/é.png",
            "a~b?c#d%20",
            @max <> @max
          ] do
        assert Key.validate_lookup(key) == :ok, "expected #{inspect(key)} to be accepted"
      end
    end

    test "rejects what could reach outside the store" do
      for {key, reason} <- [
            {nil, :not_a_binary},
            {"", :empty},
            {"a\0b", :invalid_character},
            {"a\nb", :invalid_character},
            {"a\x7Fb", :invalid_character},
            {"/etc/passwd", :absolute},
            {"\\\\host\\share", :absolute},
            {"..", :parent_segment},
            {"../a", :parent_segment},
            {"a/../b", :parent_segment},
            {"a/..", :parent_segment},
            {"..\\a", :parent_segment},
            {"a\\..\\b", :parent_segment}
          ] do
        assert Key.validate_lookup(key) == {:error, {:invalid_storage_key, reason, key}},
               "expected #{inspect(key)} to be rejected as #{inspect(reason)}"
      end
    end
  end

  describe "validate_tenant/1" do
    test "accepts a tenant that is one valid segment" do
      for tenant <- [
            "org-1",
            "42",
            "org_acme",
            "a.b",
            "A.b-c_d",
            "0b0c1d9e-8f55-4c7b-9a0c-3d0a2a1f6f11"
          ] do
        assert Key.validate_tenant(tenant) == :ok
      end
    end

    test "rejects a tenant that contains a separator or breaks a key rule" do
      for {tenant, reason} <- [
            {"a/b", :separator},
            {"/a", :separator},
            {"a/", :separator},
            {"../a", :separator},
            {"..", :parent_segment},
            {".", :dot_segment},
            {"a\\b", :invalid_character},
            {"a\nb", :invalid_character},
            {"org:123", :invalid_character},
            {"jane@example.com", :invalid_character},
            {"Acme Corp", :invalid_character},
            {"été", :invalid_character},
            {"a~b", :invalid_character},
            {"acme.", :trailing_dot},
            {"", :empty},
            {@max <> "a", :too_long},
            {nil, :not_a_binary}
          ] do
        assert Key.validate_tenant(tenant) ==
                 {:error, {:invalid_storage_key, {:tenant, reason}, tenant}},
               "expected tenant #{inspect(tenant)} to be rejected as #{inspect(reason)}"
      end
    end
  end
end
