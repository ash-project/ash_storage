defmodule AshStorage.TokenTest do
  use ExUnit.Case, async: true

  alias AshStorage.Token

  @secret "test-secret-key-32bytes-long!!!!"

  describe "sign/3" do
    test "produces a consistent signature for the same inputs" do
      sig1 = Token.sign(@secret, "some/key", 1_000_000)
      sig2 = Token.sign(@secret, "some/key", 1_000_000)
      assert sig1 == sig2
    end

    test "produces different signatures for different keys" do
      sig1 = Token.sign(@secret, "key-a", 1_000_000)
      sig2 = Token.sign(@secret, "key-b", 1_000_000)
      refute sig1 == sig2
    end

    test "produces different signatures for different expiration times" do
      sig1 = Token.sign(@secret, "some/key", 1_000_000)
      sig2 = Token.sign(@secret, "some/key", 2_000_000)
      refute sig1 == sig2
    end

    test "produces different signatures for different secrets" do
      sig1 = Token.sign("secret-a", "some/key", 1_000_000)
      sig2 = Token.sign("secret-b", "some/key", 1_000_000)
      refute sig1 == sig2
    end
  end

  describe "signed_url/4" do
    test "includes token and expires in query string" do
      url = Token.signed_url("/files/abc", @secret, "abc")
      assert url =~ "/files/abc?"
      assert url =~ "token="
      assert url =~ "expires="
    end

    test "includes disposition when specified" do
      url = Token.signed_url("/files/abc", @secret, "abc", disposition: "attachment")
      assert url =~ "disposition=attachment"
    end

    test "includes filename when specified" do
      url =
        Token.signed_url("/files/abc", @secret, "abc",
          disposition: "attachment",
          filename: "photo.jpg"
        )

      assert url =~ "filename=photo.jpg"
    end

    test "respects expires_in option" do
      now = System.system_time(:second)
      url = Token.signed_url("/files/abc", @secret, "abc", expires_in: 60)

      # Extract expires from URL
      %{query: query} = URI.parse(url)
      params = URI.decode_query(query)
      {expires, ""} = Integer.parse(params["expires"])

      # Should expire ~60 seconds from now
      assert expires >= now + 59
      assert expires <= now + 61
    end
  end
end
