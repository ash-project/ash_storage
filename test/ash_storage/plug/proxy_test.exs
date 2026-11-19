defmodule AshStorage.Plug.ProxyTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshStorage.Plug.Proxy

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp call(path, opts \\ []), do: request(:get, path, opts)

  defp request(method, path, opts \\ []) do
    plug_opts =
      Proxy.init(
        Keyword.merge(
          [service: {AshStorage.Service.Test, []}],
          opts
        )
      )

    conn(method, path)
    |> Proxy.call(plug_opts)
  end

  defp upload(key, data \\ "data") do
    AshStorage.Service.Test.upload(key, data, AshStorage.Service.Context.new([]))
  end

  defp header(conn, name) do
    case Plug.Conn.get_resp_header(conn, name) do
      [value] -> value
      [] -> nil
    end
  end

  defp signed_path(key, secret) do
    expires = System.system_time(:second) + 3600
    token = AshStorage.Token.sign(secret, key, expires)
    "/#{key}?token=#{URI.encode_www_form(token)}&expires=#{expires}"
  end

  describe "proxying files" do
    test "serves file from storage service" do
      ctx = AshStorage.Service.Context.new([])
      AshStorage.Service.Test.upload("test/file.txt", "proxy content", ctx)

      conn = call("/test/file.txt")
      assert conn.status == 200
      assert conn.resp_body == "proxy content"
      assert header(conn, "x-content-type-options") == "nosniff"
      assert header(conn, "content-disposition") == "attachment"
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

  describe "response headers" do
    @secret "proxy-secret-key-32bytes!!!!!!!!"

    test "an uploaded HTML page downloads instead of rendering" do
      upload("page.html", "<script>alert(document.domain)</script>")

      conn = call(signed_path("page.html", @secret), secret: @secret)
      assert conn.status == 200
      assert header(conn, "content-type") =~ "text/html"
      assert header(conn, "content-disposition") == "attachment"
      assert header(conn, "x-content-type-options") == "nosniff"
    end

    test "SVG is not rendered inline by the built-in sets" do
      upload("logo.svg", "<svg/>")

      for policy <- [:images, :documents] do
        conn = call("/logo.svg", inline: policy)
        assert header(conn, "content-type") =~ "image/svg+xml"
        assert header(conn, "content-disposition") == "attachment"
      end
    end

    test "allowlisted images render inline, other mounts download them" do
      upload("photo.png")

      assert header(call("/photo.png", inline: :images), "content-disposition") == "inline"
      assert header(call("/photo.png"), "content-disposition") == "attachment"
    end

    test "an explicit list allows only the listed types" do
      upload("doc.pdf")
      upload("photo.png")

      opts = [inline: ["application/pdf"]]
      assert header(call("/doc.pdf", opts), "content-disposition") == "inline"
      assert header(call("/photo.png", opts), "content-disposition") == "attachment"
    end

    test "a request can force a download" do
      upload("photo.png")

      conn = call("/photo.png?disposition=attachment", inline: :images)
      assert header(conn, "content-disposition") == "attachment"
    end

    test "a request cannot widen the policy" do
      upload("page.html")

      for opts <- [[], [inline: :images]] do
        conn = call("/page.html?disposition=inline", opts)
        assert header(conn, "content-disposition") == "attachment"
      end
    end

    test "a signed download link without its disposition still downloads" do
      upload("page.html", "<script>alert(1)</script>")

      conn = call(signed_path("page.html", @secret), secret: @secret, inline: :images)
      assert conn.status == 200
      assert header(conn, "content-disposition") == "attachment"
      assert header(conn, "x-content-type-options") == "nosniff"
    end

    test "the filename is cleaned and encoded" do
      upload("file.txt")

      for {name, expected} <- [
            {~s(a.txt"; x="y), ~s(attachment; filename="a.txt; x=y")},
            {"back\\slash.txt", ~s(attachment; filename="backslash.txt")},
            {"résumé.pdf",
             ~s(attachment; filename="r_sum_.pdf"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf)}
          ] do
        conn = call("/file.txt?filename=#{URI.encode_www_form(name)}")
        assert header(conn, "content-disposition") == expected
      end

      conn = call("/file.txt?filename[]=a")
      assert conn.status == 200
      assert header(conn, "content-disposition") == "attachment"
    end

    test "an inline response carries the filename" do
      upload("photo.png")

      conn = call("/photo.png?filename=photo.png", inline: :images)
      assert header(conn, "content-disposition") == ~s(inline; filename="photo.png")
    end

    test "only GET and HEAD are answered" do
      upload("file.txt", "secret bytes")

      for method <- [:post, :put, :patch, :delete, :options] do
        conn = request(method, "/file.txt")
        assert conn.status == 405
        assert header(conn, "allow") == "GET, HEAD"
        assert header(conn, "x-content-type-options") == "nosniff"
        refute conn.resp_body == "secret bytes"
      end

      get = call("/file.txt")
      head = request(:head, "/file.txt")
      assert head.status == 200
      assert head.resp_body == ""
      assert header(head, "content-type") == header(get, "content-type")
      assert header(head, "content-disposition") == header(get, "content-disposition")
    end

    test "uses :content_type_fallback for keys without an extension" do
      upload("abc123")
      upload("photo.png")

      assert header(call("/abc123", content_type_fallback: "text/plain"), "content-type") =~
               "text/plain"

      assert header(call("/abc123"), "content-type") =~ "application/octet-stream"

      assert header(call("/photo.png", content_type_fallback: "text/plain"), "content-type") =~
               "image/png"

      conn = call("/abc123", content_type_fallback: "image/png", inline: :images)
      assert header(conn, "content-type") =~ "image/png"
      assert header(conn, "content-disposition") == "inline"
    end

    test "error responses carry nosniff" do
      upload("file.txt")

      for {conn, status} <- [
            {call("/missing.txt"), 404},
            {call("/"), 404},
            {call("/file.txt", secret: @secret), 403}
          ] do
        assert conn.status == status
        assert header(conn, "x-content-type-options") == "nosniff"
      end
    end

    test "init/1 rejects an invalid :inline option" do
      assert_raise ArgumentError, fn ->
        Proxy.init(service: {AshStorage.Service.Test, []}, inline: :all)
      end

      assert_raise ArgumentError, fn ->
        Proxy.init(service: {AshStorage.Service.Test, []}, content_type_fallback: "plain")
      end
    end
  end
end
