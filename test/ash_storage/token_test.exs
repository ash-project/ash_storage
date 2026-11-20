defmodule AshStorage.TokenTest do
  use ExUnit.Case, async: true

  alias AshStorage.Token

  doctest AshStorage.Token

  @secret "test-secret-key-32bytes-long!!!!"

  @download [purpose: :download]

  defp now, do: System.system_time(:second)

  defp b64(data), do: Base.url_encode64(data, padding: false)

  defp hmac(secret, data), do: b64(:crypto.mac(:hmac, :sha256, secret, data))

  # Signs an arbitrary payload part, for tokens that `sign/3` refuses to make.
  defp craft_raw(payload_part, secret \\ @secret) do
    signed = "v1." <> payload_part
    signed <> "." <> hmac(secret, signed)
  end

  defp craft(payload, secret \\ @secret), do: craft_raw(b64(Jason.encode!(payload)), secret)

  defp valid_payload(extra \\ %{}) do
    Map.merge(%{"p" => "download", "i" => now(), "e" => now() + 3600, "s" => "k"}, extra)
  end

  defp payload_of(token) do
    [_, payload, _] = String.split(token, ".")
    payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp verify(token, opts \\ []), do: Token.verify(token, @secret, @download ++ opts)

  describe "claim token format" do
    test "is v1.<payload>.<signature> with a JSON payload" do
      token = Token.sign(%{"s" => "a/b"}, @secret, @download)

      assert token =~ ~r/\Av1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}\z/

      assert %{"p" => "download", "i" => i, "e" => e, "s" => "a/b"} = payload_of(token)
      assert is_integer(i) and is_integer(e)
    end
  end

  describe "sign/3 and verify/3 round trip" do
    test "with the default lifetime" do
      token = Token.sign(%{"s" => "k", "d" => "attachment", "f" => "a.png"}, @secret, @download)

      assert {:ok, claims} = verify(token)
      assert %{"p" => "download", "s" => "k", "d" => "attachment", "f" => "a.png"} = claims
      assert claims["e"] - claims["i"] == 3600
    end

    test "with :expires_in and :issued_at" do
      issued_at = now() - 5
      opts = @download ++ [expires_in: 60, issued_at: issued_at]
      token = Token.sign(%{"s" => "k", "t" => "image/png"}, @secret, opts)

      assert {:ok, %{"i" => ^issued_at, "e" => e, "t" => "image/png"}} = verify(token)
      assert e == issued_at + 60
    end

    test "drops claims whose value is nil" do
      token = Token.sign(%{"s" => "k", "f" => nil}, @secret, @download)

      assert {:ok, claims} = verify(token)
      refute Map.has_key?(claims, "f")
    end
  end

  describe "sign/3 raises" do
    test "on bad options and claims" do
      for {claims, opts} <- [
            {%{"s" => "k"}, []},
            {%{"s" => "k"}, [purpose: :upload]},
            {%{s: "k"}, @download},
            {%{"e" => 1}, @download},
            {%{"a" => "x"}, @download},
            {%{"x" => "x"}, @download},
            {%{"zz" => "x"}, @download},
            {%{"s" => "k"}, @download ++ [expires_in: 0]},
            {%{"s" => "k"}, @download ++ [expires_in: -1]},
            {%{"s" => "k"}, @download ++ [expires_in: 1.5]},
            {"k", @download},
            {[{"s", "k"}], @download}
          ] do
        assert_raise ArgumentError, fn -> Token.sign(claims, @secret, opts) end
      end
    end
  end

  describe "error messages" do
    test "never contain the arguments, also when they are swapped" do
      secret = "my-secret-value"

      for fun <- [
            fn -> Token.sign(secret, %{"s" => "k"}, @download) end,
            fn -> Token.sign(%{"s" => "k"}, @download, secret) end,
            fn -> Token.sign(%{"s" => "k"}, secret, secret) end,
            fn -> Token.sign(%{"s" => "k"}, @secret, purpose: secret) end,
            fn -> Token.verify("token", secret, secret) end,
            fn -> Token.verify("token", @download, secret) end,
            fn -> Token.verify("token", @secret, purpose: secret) end
          ] do
        error = assert_raise ArgumentError, fun
        refute Exception.message(error) =~ secret
      end
    end
  end

  describe "verify/3 answers :invalid" do
    test "for malformed and altered tokens" do
      token = Token.sign(%{"s" => "k"}, @secret, @download)
      [_, payload, signature] = String.split(token, ".")

      other_payload =
        payload_of(token) |> Map.put("s", "other") |> Jason.encode!() |> b64()

      # The last character holds two unused bits; flipping one gives another
      # string that decodes to the same 32 bytes.
      alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
      {head, <<last>>} = String.split_at(signature, -1)
      index = Enum.find_index(alphabet, &(&1 == last))
      same_bytes = head <> <<Enum.at(alphabet, Bitwise.bxor(index, 1))>>

      assert Base.url_decode64(same_bytes, padding: false) ==
               Base.url_decode64(signature, padding: false)

      {first, rest} = String.split_at(signature, 1)
      changed = if(first == "A", do: "B", else: "A") <> rest

      for bad <- [
            nil,
            123,
            "",
            "abc",
            # the format before v1: an HMAC of "<key>:<expires_at>"
            hmac(@secret, "k:#{now() + 3600}"),
            "v1.x",
            token <> ".x",
            "v2." <> payload <> "." <> signature,
            "v1." <> other_payload <> "." <> signature,
            "v1." <> payload <> "." <> changed,
            "v1." <> payload <> "." <> same_bytes,
            token <> "=",
            String.slice(token, 0..-2//1),
            Token.sign(%{"s" => "k"}, "another-secret", @download)
          ] do
        assert verify(bad) == {:error, :invalid}, "expected :invalid for #{inspect(bad)}"
      end
    end

    test "for signed payloads of the wrong shape" do
      for bad <- [
            craft([1]),
            craft_raw("not base64!"),
            craft(Map.delete(valid_payload(), "e")),
            craft(valid_payload(%{"e" => now() + 3600.0})),
            craft(Map.delete(valid_payload(), "i")),
            craft(valid_payload(%{"p" => 1})),
            craft(valid_payload(%{"zz" => "x"}))
          ] do
        assert verify(bad) == {:error, :invalid}, "expected :invalid for #{inspect(bad)}"
      end
    end
  end

  describe "verify/3 checks" do
    test "the purpose, before the expiry" do
      assert verify(craft(valid_payload(%{"p" => "blob"}))) == {:error, :wrong_purpose}

      expired = valid_payload(%{"p" => "blob", "i" => now() - 7200, "e" => now() - 3600})
      assert verify(craft(expired)) == {:error, :wrong_purpose}
    end

    test "the expiry, before the lifetime" do
      old = Token.sign(%{"s" => "k"}, @secret, @download ++ [issued_at: now() - 7200])
      assert verify(old) == {:error, :expired}
      assert verify(old, max_lifetime_seconds: 60) == {:error, :expired}

      ends_now =
        Token.sign(%{"s" => "k"}, @secret, @download ++ [issued_at: now() - 10, expires_in: 10])

      assert verify(ends_now) == {:error, :expired}
    end

    test "the lifetime the token was issued with" do
      token = Token.sign(%{"s" => "k"}, @secret, @download ++ [expires_in: 3600])

      assert verify(token, max_lifetime_seconds: 3599) == {:error, :lifetime_exceeded}
      assert {:ok, _} = verify(token, max_lifetime_seconds: 3600)
      assert {:ok, _} = verify(token, max_lifetime_seconds: nil)
    end

    test "only the token's own times for the lifetime" do
      opts = @download ++ [issued_at: now() + 300, expires_in: 60]
      token = Token.sign(%{"s" => "k"}, @secret, opts)

      assert {:ok, _} = verify(token, max_lifetime_seconds: 60)
    end

    test "raises on bad options" do
      token = Token.sign(%{"s" => "k"}, @secret, @download)

      assert_raise ArgumentError, fn -> Token.verify(token, @secret, []) end
      assert_raise ArgumentError, fn -> Token.verify(token, @secret, purpose: :upload) end

      for max <- [0, -1, "60", 1.5] do
        assert_raise ArgumentError, fn -> verify(token, max_lifetime_seconds: max) end
      end
    end
  end

  def secret_from_process, do: Process.get(:token_test_secret)

  describe "secrets" do
    test "a list signs with its first entry and verifies with any" do
      token = Token.sign(%{"s" => "k"}, ["new", "old"], @download)

      assert {:ok, _} = Token.verify(token, "new", @download)
      assert Token.verify(token, "old", @download) == {:error, :invalid}

      old_token = Token.sign(%{"s" => "k"}, "old", @download)
      assert {:ok, _} = Token.verify(old_token, ["new", "old"], @download)
    end

    test "a function or an MFA is called on every use" do
      for secret <- [fn -> secret_from_process() end, {__MODULE__, :secret_from_process, []}] do
        Process.put(:token_test_secret, "first")
        token = Token.sign(%{"s" => "k"}, secret, @download)
        assert {:ok, _} = Token.verify(token, secret, @download)

        Process.put(:token_test_secret, "second")
        assert Token.verify(token, secret, @download) == {:error, :invalid}

        assert {:ok, _} =
                 Token.verify(Token.sign(%{"s" => "k"}, secret, @download), "second", @download)
      end
    end

    test "a function may return a list" do
      token = Token.sign(%{"s" => "k"}, "old", @download)
      assert {:ok, _} = Token.verify(token, fn -> ["new", "old"] end, @download)
    end

    test "anything else raises without revealing the secret" do
      token = Token.sign(%{"s" => "k"}, @secret, @download)

      for secret <- [nil, "", [], ["hunter2", nil], 123, fn x -> x end, fn -> nil end] do
        error = assert_raise ArgumentError, fn -> Token.sign(%{"s" => "k"}, secret, @download) end
        refute Exception.message(error) =~ "hunter2"

        error = assert_raise ArgumentError, fn -> Token.verify(token, secret, @download) end
        refute Exception.message(error) =~ "hunter2"
      end
    end
  end

  describe "signed_url/4" do
    defp url_claims(url) do
      %URI{path: path, query: query} = URI.parse(url)
      params = URI.decode_query(query)
      assert Map.keys(params) == ["token"]
      assert {:ok, claims} = Token.verify(params["token"], @secret, @download)
      {path, claims}
    end

    test "adds one token parameter for the key" do
      url = Token.signed_url("/files/a/b", @secret, "a/b")

      assert url =~ ~r/\A\/files\/a\/b\?token=v1\.[^&]+\z/
      assert {"/files/a/b", %{"s" => "a/b"} = claims} = url_claims(url)
      assert claims["e"] - claims["i"] == 3600
      refute Enum.any?(["d", "f", "t"], &Map.has_key?(claims, &1))
    end

    test "turns each option into its claim" do
      url =
        Token.signed_url("/files/k", @secret, "k",
          expires_in: 60,
          disposition: "attachment",
          filename: "a b.png",
          content_type: "image/png"
        )

      assert {_, claims} = url_claims(url)
      assert %{"d" => "attachment", "f" => "a b.png", "t" => "image/png"} = claims
      assert claims["e"] - claims["i"] == 60

      assert {_, %{"d" => "attachment"}} =
               url_claims(Token.signed_url("/files/k", @secret, "k", disposition: :attachment))
    end

    test "sets no disposition for inline or nil, and no filename for an empty one" do
      for opts <- [[disposition: "inline"], [disposition: :inline], [disposition: nil]] do
        assert {_, claims} = url_claims(Token.signed_url("/files/k", @secret, "k", opts))
        refute Map.has_key?(claims, "d")
      end

      assert {_, claims} = url_claims(Token.signed_url("/files/k", @secret, "k", filename: ""))
      refute Map.has_key?(claims, "f")
    end

    test "never puts a swapped argument into an error message" do
      secret = "my-secret-value"

      for fun <- [
            fn -> Token.signed_url([secret, "old"], "/files/k", "k") end,
            fn -> Token.signed_url("/files/k", "k", [secret]) end,
            fn -> Token.signed_url("/files/k", "k", "k", secret) end
          ] do
        error = assert_raise ArgumentError, fun
        refute Exception.message(error) =~ secret
      end
    end

    test "raises on invalid options" do
      for opts <- [[disposition: "x"], [filename: 1], [content_type: :png], [expires_in: 0]] do
        assert_raise ArgumentError, fn -> Token.signed_url("/files/k", @secret, "k", opts) end
      end
    end
  end
end
