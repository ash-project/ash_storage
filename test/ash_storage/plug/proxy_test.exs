defmodule AshStorage.Plug.ProxyTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshStorage.Plug.Proxy

  import AshStorage.Test.SignedUrls

  defmodule RecordingService do
    @moduledoc false
    # Tells the test process about every download it is asked for.
    @behaviour AshStorage.Service

    @impl true
    def upload(_, _, _), do: :ok
    @impl true
    def download(key, ctx) do
      send(Keyword.fetch!(ctx.service_opts, :test_pid), {:download_called, key})
      {:ok, "data"}
    end

    @impl true
    def delete(_, _), do: :ok
    @impl true
    def exists?(_, _), do: {:ok, true}
    @impl true
    def url(key, _), do: "https://example.test/#{key}"
  end

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

    test "serves a file with a valid token" do
      upload("secret.txt", "secret data")

      conn = call(signed_path("secret.txt", @secret), secret: @secret)
      assert conn.status == 200
      assert conn.resp_body == "secret data"
    end

    test "rejects a missing, a malformed and another key's token without a download" do
      service = {RecordingService, test_pid: self()}

      for path <- ["/secret.txt", "/secret.txt?token=garbage", signed_path("other.txt", @secret)] do
        path = String.replace(path, "/other.txt", "/secret.txt")
        conn = call(path, service: service, secret: @secret)

        assert conn.status == 403, "expected 403 for #{path}"
        assert conn.resp_body == "Forbidden"
        refute_received {:download_called, _}
      end
    end

    test "rejects missing, altered, expired and foreign tokens without a download" do
      service = {RecordingService, test_pid: self()}

      upload("secret.txt")
      assert call(crafted_path("secret.txt", @secret), secret: @secret).status == 200

      for {description, path} <- rejected_paths("secret.txt", @secret) do
        conn = call(path, service: service, secret: @secret)

        assert conn.status == 403, "expected 403 for #{description}"
        assert conn.resp_body == "Forbidden"
        assert header(conn, "x-content-type-options") == "nosniff"
        refute_received {:download_called, _}
      end
    end

    test "a mount with :max_lifetime_seconds rejects longer-lived URLs" do
      upload("file.txt")
      path = signed_path("file.txt", @secret, expires_in: 3600)

      assert call(path, secret: @secret, max_lifetime_seconds: 600).status == 403
      assert call(path, secret: @secret, max_lifetime_seconds: 3600).status == 200
    end

    test "a list of secrets accepts URLs signed with any of them" do
      upload("file.txt")
      path = signed_path("file.txt", "old-secret")

      assert call(path, secret: ["new-secret", "old-secret"]).status == 200
      assert call(path, secret: ["new-secret"]).status == 403
    end

    test "an unsigned mount ignores a token parameter" do
      upload("file.txt")

      assert call("/file.txt?token=garbage").status == 200
    end

    test "parameters added to a signed URL do not change the response (#68)" do
      upload("page.html", "<script>alert(1)</script>")
      added = "&disposition=attachment&filename=#{URI.encode_www_form(~s(a.txt"; x="y))}"

      conn = call(signed_path("page.html", @secret) <> added, secret: @secret)
      assert conn.status == 200
      assert header(conn, "content-disposition") == "attachment"

      signed = signed_path("page.html", @secret, disposition: "attachment", filename: "page.html")

      for path <- [signed, signed <> "&filename=invoice.pdf"] do
        conn = call(path, secret: @secret, inline: ["text/html"])
        assert header(conn, "content-disposition") == ~s(attachment; filename="page.html")
      end
    end

    test "the content type comes from the token" do
      upload("abc123")

      path = signed_path("abc123", @secret, content_type: "image/png")

      conn = call(path, secret: @secret, inline: :images)
      assert header(conn, "content-type") =~ "image/png"
      assert header(conn, "content-disposition") == "inline"

      conn = call(path, secret: @secret)
      assert header(conn, "content-type") =~ "image/png"
      assert header(conn, "content-disposition") == "attachment"

      conn =
        call(signed_path("abc123", @secret, filename: "photo.png"),
          secret: @secret,
          inline: :images
        )

      assert header(conn, "content-type") =~ "image/png"
      assert header(conn, "content-disposition") == ~s(inline; filename="photo.png")
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

  describe "keys that could reach outside the store" do
    # `path_info` is set directly: a router hands the plug raw segments, and a
    # plug in front of the mount may have decoded them.
    defp call_with_path_info(path_info, opts \\ []) do
      opts = Keyword.put_new(opts, :service, {RecordingService, test_pid: self()})
      conn = %{conn(:get, "/") | path_info: path_info}
      Proxy.call(conn, Proxy.init(opts))
    end

    test "answers 404 without calling the service" do
      for path_info <- [
            ["..", "secret.txt"],
            ["a", "..", "secret.txt"],
            ["a", ".."],
            ["../secret.txt"],
            ["..\\secret.txt"],
            ["/etc/passwd"],
            ["a\0.txt"],
            ["a\nb"]
          ] do
        conn = call_with_path_info(path_info)

        assert conn.status == 404, "expected 404 for #{inspect(path_info)}"
        assert header(conn, "x-content-type-options") == "nosniff"
        refute_received {:download_called, _}
      end
    end

    test "answers 404 before the signature is checked" do
      assert call_with_path_info(["..", "secret.txt"], secret: @secret).status == 404
    end

    test "a `..` segment over the Disk service is a 404, not a 502" do
      root =
        Path.join(System.tmp_dir!(), "ash_storage_proxy_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "store"))
      File.write!(Path.join(root, "secret.txt"), "secret")
      on_exit(fn -> File.rm_rf!(root) end)

      conn =
        call("/../secret.txt",
          service: {AshStorage.Service.Disk, root: Path.join(root, "store"), base_url: "/files"}
        )

      assert conn.status == 404
      refute conn.resp_body =~ "secret"
    end

    test "still serves keys that the write-side rules now reject" do
      for key <- ["back\\slash.txt", "a/./b.txt", "trailing.txt/"] do
        conn = call_with_path_info(String.split(key, "/"))

        assert conn.status == 200, "expected 200 for #{inspect(key)}"
        assert_received {:download_called, ^key}
      end
    end
  end
end
