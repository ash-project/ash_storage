defmodule AshStorage.Plug.ProxyTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshStorage.Plug.Proxy

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp call(path, opts \\ []) do
    plug_opts =
      Proxy.init(
        Keyword.merge(
          [service: {AshStorage.Service.Test, []}],
          opts
        )
      )

    conn(:get, path)
    |> Proxy.call(plug_opts)
  end

  describe "proxying files" do
    test "serves file from storage service" do
      ctx = AshStorage.Service.Context.new([])
      AshStorage.Service.Test.upload("test/file.txt", "proxy content", ctx)

      conn = call("/test/file.txt")
      assert conn.status == 200
      assert conn.resp_body == "proxy content"
    end

    test "sets content-type from key extension" do
      ctx = AshStorage.Service.Context.new([])
      AshStorage.Service.Test.upload("photo.jpg", "image data", ctx)

      conn = call("/photo.jpg")
      assert conn.status == 200
      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "image/jpeg"
    end

    test "returns 404 for missing files" do
      conn = call("/nonexistent.txt")
      assert conn.status == 404
    end

    test "returns 404 for empty path" do
      conn = call("/")
      assert conn.status == 404
    end
  end

  describe "signed URLs" do
    @secret "proxy-secret-key-32bytes!!!!!!!!"

    test "rejects requests without token" do
      ctx = AshStorage.Service.Context.new([])
      AshStorage.Service.Test.upload("secret.txt", "secret data", ctx)

      conn = call("/secret.txt", secret: @secret)
      assert conn.status == 403
    end

    test "serves file with valid token" do
      ctx = AshStorage.Service.Context.new([])
      AshStorage.Service.Test.upload("secret.txt", "secret data", ctx)

      expires = System.system_time(:second) + 3600
      token = AshStorage.Token.sign(@secret, "secret.txt", expires)

      plug_opts =
        Proxy.init(
          service: {AshStorage.Service.Test, []},
          secret: @secret
        )

      conn =
        conn(:get, "/secret.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body == "secret data"
    end
  end
end
