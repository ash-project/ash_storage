defmodule AshStorage.Plug.SignedRequestTest do
  use ExUnit.Case, async: true

  alias AshStorage.Plug.SignedRequest

  def secret do
    send(self(), :secret_called)
    "mfa-secret"
  end

  describe "init/1" do
    test "accepts no secret and every secret form" do
      for secret <- [nil, "s", ["new", "old"], &__MODULE__.secret/0, {__MODULE__, :secret, []}] do
        assert %{secret: ^secret, max_lifetime_seconds: nil} =
                 SignedRequest.init(secret: secret)
      end

      assert %{max_lifetime_seconds: 600} =
               SignedRequest.init(secret: "s", max_lifetime_seconds: 600)
    end

    test "rejects other secrets without naming the value" do
      for secret <- ["", [], ["hunter2", 1], 123, fn x -> x end] do
        error = assert_raise ArgumentError, fn -> SignedRequest.init(secret: secret) end
        assert Exception.message(error) =~ ":secret"
        refute Exception.message(error) =~ "hunter2"
      end
    end

    test "rejects an invalid :max_lifetime_seconds, and one without a secret" do
      for max <- [0, -1, "60", 1.5] do
        assert_raise ArgumentError, ~r/:max_lifetime_seconds/, fn ->
          SignedRequest.init(secret: "s", max_lifetime_seconds: max)
        end
      end

      assert_raise ArgumentError, ~r/requires the :secret option/, fn ->
        SignedRequest.init(max_lifetime_seconds: 600)
      end
    end

    test "does not call a function or MFA secret, and its result can be escaped" do
      for secret <- [&__MODULE__.secret/0, {__MODULE__, :secret, []}] do
        mount = SignedRequest.init(secret: secret, max_lifetime_seconds: 60)

        assert Macro.escape(mount)
        refute_received :secret_called
      end
    end
  end
end
