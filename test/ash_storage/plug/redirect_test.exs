defmodule AshStorage.Plug.RedirectTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshStorage.Plug.Redirect

  import AshStorage.Test.SignedUrls

  defmodule CapturingService do
    @moduledoc false
    # Reports the options `url/2` receives to the test process.
    @behaviour AshStorage.Service

    @impl true
    def upload(_, _, _), do: :ok
    @impl true
    def download(_, _), do: {:error, :not_found}
    @impl true
    def delete(_, _), do: :ok
    @impl true
    def exists?(_, _), do: {:ok, false}

    @impl true
    def url(key, ctx) do
      parent = Keyword.fetch!(ctx.service_opts, :test_pid)
      send(parent, {:url_called, key, ctx.service_opts})
      "https://example.test/#{key}"
    end
  end

  @azure {AshStorage.Service.AzureBlob,
          account: "acct",
          account_key: Base.encode64("test account key"),
          container: "c",
          presigned: true}

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp call(path, opts \\ []) do
    plug_opts =
      Redirect.init(
        Keyword.merge(
          [service: {AshStorage.Service.Test, base_url: "https://cdn.example/storage"}],
          opts
        )
      )

    conn(:get, path)
    |> Plug.Conn.fetch_query_params()
    |> Redirect.call(plug_opts)
  end

  # Returns the service options `url/2` received.
  defp captured_opts(path, opts \\ []) do
    call(path, Keyword.put_new(opts, :service, {CapturingService, test_pid: self()}))
    assert_received {:url_called, _key, service_opts}
    service_opts
  end

  # Returns the response-header parameters of the Azure SAS URL.
  defp azure_params(path, opts \\ []) do
    [location] = path |> call([service: @azure] ++ opts) |> Plug.Conn.get_resp_header("location")

    location
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.take(["rscd", "rsct"])
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  describe "redirecting" do
    test "issues 302 with location pointing at service.url/2" do
      conn = call("/photos/cat.jpg")

      assert conn.status == 302

      assert ["https://cdn.example/storage/photos/cat.jpg"] =
               Plug.Conn.get_resp_header(conn, "location")

      assert conn.resp_body == ""
    end

    test "sets cache-control: no-store, private" do
      conn = call("/photos/cat.jpg")

      assert ["no-store, private"] = Plug.Conn.get_resp_header(conn, "cache-control")
    end

    test "uses configurable :status (e.g. 307)" do
      conn = call("/photos/cat.jpg", status: 307)

      assert conn.status == 307
    end

    test "returns 404 for empty path" do
      conn = call("/")

      assert conn.status == 404
    end

    test "forwards disposition/filename query params into service opts" do
      plug_opts =
        Redirect.init(service: {CapturingService, test_pid: self()})

      conn(:get, "/doc.pdf?disposition=attachment&filename=annual-report.pdf")
      |> Plug.Conn.fetch_query_params()
      |> Redirect.call(plug_opts)

      assert_received {:url_called, "doc.pdf", opts}
      assert opts[:disposition] == "attachment"
      assert opts[:filename] == "annual-report.pdf"
    end
  end

  describe "signed URLs" do
    @secret "redirect-secret-key-32bytes!!!!!!"

    test "redirects when the token is valid" do
      conn = call(signed_path("secret.txt", @secret), secret: @secret)

      assert conn.status == 302

      assert ["https://cdn.example/storage/secret.txt"] =
               Plug.Conn.get_resp_header(conn, "location")
    end

    test "rejects a missing, a malformed and another key's token without asking for a URL" do
      service = {CapturingService, test_pid: self()}

      for path <- ["/secret.txt", "/secret.txt?token=garbage", signed_path("other.txt", @secret)] do
        path = String.replace(path, "/other.txt", "/secret.txt")
        conn = call(path, service: service, secret: @secret)

        assert conn.status == 403, "expected 403 for #{path}"
        assert header(conn, "location") == nil
        refute_received {:url_called, _, _}
      end
    end

    test "rejects missing, altered, expired and foreign tokens without asking for a URL" do
      service = {CapturingService, test_pid: self()}

      assert call(crafted_path("secret.txt", @secret), secret: @secret).status == 302

      for {description, path} <- rejected_paths("secret.txt", @secret) do
        conn = call(path, service: service, secret: @secret)

        assert conn.status == 403, "expected 403 for #{description}"
        assert conn.resp_body == "Forbidden"
        assert header(conn, "x-content-type-options") == "nosniff"
        assert header(conn, "location") == nil
        refute_received {:url_called, _, _}
      end
    end

    test "a mount with :max_lifetime_seconds rejects longer-lived URLs" do
      path = signed_path("secret.txt", @secret, expires_in: 3600)

      assert call(path, secret: @secret, max_lifetime_seconds: 600).status == 403
      assert call(path, secret: @secret, max_lifetime_seconds: 3600).status == 302
    end

    test "a list of secrets accepts URLs signed with any of them" do
      path = signed_path("secret.txt", "old-secret")

      assert call(path, secret: ["new-secret", "old-secret"]).status == 302
      assert call(path, secret: ["new-secret"]).status == 403
    end

    test "an unsigned mount ignores a token parameter" do
      assert call("/secret.txt?token=garbage").status == 302
    end

    test "parameters added to a signed URL do not reach Azure (#68)" do
      path = signed_path("doc.pdf", @secret) <> "&disposition=attachment&filename=evil.exe"

      assert azure_params(path, secret: @secret) == %{"rscd" => "attachment"}
    end

    test "the claims reach the service" do
      path = signed_path("abc123", @secret, disposition: "attachment", filename: ~s(a"/b.png))
      opts = captured_opts(path, secret: @secret)
      assert opts[:disposition] == "attachment"
      assert opts[:filename] == "ab.png"

      path = signed_path("abc123", @secret, content_type: "image/png")
      opts = captured_opts(path, secret: @secret, inline: :images)
      assert opts[:content_type] == "image/png"
      refute Keyword.has_key?(opts, :disposition)
    end
  end

  describe "inline policy" do
    test "asks for an attachment by default" do
      opts = captured_opts("/photo.png")
      assert opts[:disposition] == "attachment"
      refute Keyword.has_key?(opts, :content_type)
    end

    test "passes the content type and no disposition for an allowed type" do
      opts = captured_opts("/photo.png", inline: :images)
      refute Keyword.has_key?(opts, :disposition)
      assert opts[:content_type] == "image/png"

      opts = captured_opts("/photo.png?disposition=attachment", inline: :images)
      assert opts[:disposition] == "attachment"
    end

    test "a request cannot widen the policy" do
      opts = captured_opts("/page.html?disposition=inline", inline: :images)
      assert opts[:disposition] == "attachment"
    end

    test "keeps a configured disposition for allowed types and overrides it otherwise" do
      service = {CapturingService, test_pid: self(), disposition: "attachment"}
      opts = captured_opts("/photo.png", service: service, inline: :images)
      assert opts[:disposition] == "attachment"

      service = {CapturingService, test_pid: self(), disposition: "inline"}
      opts = captured_opts("/page.html", service: service, inline: :images)
      assert Keyword.get_values(opts, :disposition) == ["attachment"]
    end

    test "cleans the filename" do
      assert captured_opts("/doc.pdf?filename=a%22b")[:filename] == "ab"
    end

    test "reaches presigned Azure URLs" do
      assert azure_params("/doc.pdf") == %{"rscd" => "attachment"}

      assert azure_params("/doc.pdf?disposition=inline%3B%20x&filename=a%22b") ==
               %{"rscd" => ~s(attachment; filename="ab")}

      assert azure_params("/photo.png", inline: :images) == %{"rsct" => "image/png"}

      assert azure_params("/doc.pdf?disposition=attachment&filename=evil.exe") ==
               %{"rscd" => ~s(attachment; filename="evil.exe")}
    end
  end

  describe "methods and headers" do
    @secret "redirect-secret-key-32bytes!!!!!!"

    test "only GET and HEAD are answered" do
      plug_opts = Redirect.init(service: {CapturingService, test_pid: self()})

      conn = conn(:post, "/doc.pdf") |> Redirect.call(plug_opts)
      assert conn.status == 405
      assert header(conn, "allow") == "GET, HEAD"
      refute_received {:url_called, _, _}

      assert (conn(:head, "/doc.pdf") |> Redirect.call(plug_opts)).status == 302
    end

    test "every response carries nosniff and the cache-control stays" do
      plug_opts = Redirect.init(service: {AshStorage.Service.Test, base_url: "https://x"})

      for {conn, status} <- [
            {call("/doc.pdf"), 302},
            {call("/doc.pdf", secret: @secret), 403},
            {call("/"), 404},
            {conn(:put, "/doc.pdf") |> Redirect.call(plug_opts), 405}
          ] do
        assert conn.status == status
        assert header(conn, "x-content-type-options") == "nosniff"
      end

      assert header(call("/doc.pdf"), "cache-control") == "no-store, private"
    end

    test "init/1 rejects an invalid :inline option" do
      assert_raise ArgumentError, fn ->
        Redirect.init(service: {AshStorage.Service.Test, []}, inline: :all)
      end
    end
  end

  describe "keys that could reach outside the store" do
    test "answers 404 without asking the service for a URL" do
      plug_opts = Redirect.init(service: {CapturingService, test_pid: self()})

      for path_info <- [
            ["..", "secret.txt"],
            ["a", ".."],
            ["../secret.txt"],
            ["..\\secret.txt"],
            ["/etc/passwd"],
            ["a\0.txt"],
            ["a\r\nx-injected: 1"]
          ] do
        conn = Redirect.call(%{conn(:get, "/") | path_info: path_info}, plug_opts)

        assert conn.status == 404, "expected 404 for #{inspect(path_info)}"
        assert header(conn, "location") == nil
        assert header(conn, "x-content-type-options") == "nosniff"
        refute_received {:url_called, _, _}
      end
    end

    test "answers 404 before the signature is checked" do
      assert call("/../secret.txt", secret: @secret).status == 404
    end

    test "still redirects for a key that the write-side rules now reject" do
      plug_opts = Redirect.init(service: {CapturingService, test_pid: self()})
      conn = Redirect.call(%{conn(:get, "/") | path_info: ["back\\slash.txt"]}, plug_opts)

      assert conn.status == 302
      assert_received {:url_called, "back\\slash.txt", _}
    end
  end
end
