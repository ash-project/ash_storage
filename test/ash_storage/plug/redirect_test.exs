defmodule AshStorage.Plug.RedirectTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshStorage.Plug.Redirect

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
      defmodule CapturingService do
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
end
