defmodule AshStorage.Plug.RedirectTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshStorage.Plug.Redirect

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

    test "rejects requests without a token" do
      conn = call("/secret.txt", secret: @secret)

      assert conn.status == 403
    end

    test "rejects expired tokens" do
      expires = System.system_time(:second) - 60
      token = AshStorage.Token.sign(@secret, "secret.txt", expires)

      plug_opts =
        Redirect.init(
          service: {AshStorage.Service.Test, base_url: "https://cdn.example/storage"},
          secret: @secret
        )

      conn =
        conn(:get, "/secret.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> Redirect.call(plug_opts)

      assert conn.status == 403
    end

    test "rejects tampered tokens" do
      expires = System.system_time(:second) + 3600
      token = AshStorage.Token.sign(@secret, "different-key.txt", expires)

      plug_opts =
        Redirect.init(
          service: {AshStorage.Service.Test, base_url: "https://cdn.example/storage"},
          secret: @secret
        )

      conn =
        conn(:get, "/secret.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> Redirect.call(plug_opts)

      assert conn.status == 403
    end

    test "redirects when token is valid" do
      expires = System.system_time(:second) + 3600
      token = AshStorage.Token.sign(@secret, "secret.txt", expires)

      plug_opts =
        Redirect.init(
          service: {AshStorage.Service.Test, base_url: "https://cdn.example/storage"},
          secret: @secret
        )

      conn =
        conn(:get, "/secret.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> Redirect.call(plug_opts)

      assert conn.status == 302

      assert ["https://cdn.example/storage/secret.txt"] =
               Plug.Conn.get_resp_header(conn, "location")
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
end
