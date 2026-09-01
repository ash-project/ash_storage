defmodule AshStorage.Plug.ProxyTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshStorage.Plug.Proxy
  alias AshStorage.Service
  alias AshStorage.Test.LayeredPost

  defmodule PrefixReadLayer do
    @behaviour AshStorage.Layer

    @impl true
    def default_metadata_key(_opts), do: "proxy-prefix"

    @impl true
    def read(read, _opts) do
      {:ok, %{read | data: String.replace_prefix(read.data, "wrapped:", "")}}
    end
  end

  setup do
    Service.Test.reset!()
    :ok
  end

  defp call(path, opts \\ []) do
    plug_opts =
      Proxy.init(
        Keyword.merge(
          [service: {Service.Test, []}],
          opts
        )
      )

    conn(:get, path)
    |> Proxy.call(plug_opts)
  end

  describe ":proxy_access_requirement" do
    setup do
      original = Application.get_env(:ash_storage, :proxy_access_requirement)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:ash_storage, :proxy_access_requirement)
        else
          Application.put_env(:ash_storage, :proxy_access_requirement, original)
        end
      end)

      :ok
    end

    test "defaults to :require — a blob-aware route without :access raises" do
      Application.delete_env(:ash_storage, :proxy_access_requirement)

      assert_raise ArgumentError, ~r/requires an explicit/, fn ->
        Proxy.init(resource: LayeredPost, attachment: :cover_image)
      end
    end

    test ":require raises for a blob-aware route configured without :access" do
      Application.put_env(:ash_storage, :proxy_access_requirement, :require)

      assert_raise ArgumentError, ~r/requires an explicit/, fn ->
        Proxy.init(resource: LayeredPost, attachment: :cover_image)
      end
    end

    test ":require allows an explicit access: :public on a blob-aware route" do
      Application.put_env(:ash_storage, :proxy_access_requirement, :require)

      assert %{access: :public} =
               Proxy.init(resource: LayeredPost, attachment: :cover_image, access: :public)
    end

    test ":warn logs a warning but allows a blob-aware route without :access" do
      Application.put_env(:ash_storage, :proxy_access_requirement, :warn)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{blob_resource: blob_resource} =
                   Proxy.init(resource: LayeredPost, attachment: :cover_image)

          assert blob_resource != nil
        end)

      assert log =~ "serve those blobs publicly"
    end

    test ":off does not raise for a blob-aware route without :access" do
      Application.put_env(:ash_storage, :proxy_access_requirement, :off)

      assert %{blob_resource: blob_resource} =
               Proxy.init(resource: LayeredPost, attachment: :cover_image)

      assert blob_resource != nil
    end

    test "a raw (non-blob-aware) public route is unaffected by :require" do
      Application.put_env(:ash_storage, :proxy_access_requirement, :require)

      assert %{access: :public} = Proxy.init(service: {Service.Test, []})
    end
  end

  describe "proxying files" do
    test "serves file from storage service" do
      ctx = Service.Context.new([])
      Service.Test.upload("test/file.txt", "proxy content", ctx)

      conn = call("/test/file.txt")
      assert conn.status == 200
      assert conn.resp_body == "proxy content"
    end

    test "serves file through BlobIO with configured service opts" do
      table = __MODULE__.ConfiguredProxy
      Service.Test.start(name: table)
      Service.Test.reset!(name: table)

      ctx = Service.Context.new(name: table)
      Service.Test.upload("test/file.txt", "configured proxy content", ctx)

      conn = call("/test/file.txt", service: {Service.Test, [name: table]})
      assert conn.status == 200
      assert conn.resp_body == "configured proxy content"
    end

    test "passes explicit layers to the key-only BlobIO proxy handoff" do
      ctx = Service.Context.new([])
      Service.Test.upload("test/file.txt", "wrapped:proxy content", ctx)

      conn = call("/test/file.txt", layers: [PrefixReadLayer])
      assert conn.status == 200
      assert conn.resp_body == "proxy content"
    end

    test "serves blob-aware proxy requests through persisted layer metadata" do
      {:ok, attachment} = AshStorage.Info.attachment(LayeredPost, :cover_image)

      bctx =
        AshStorage.BlobIO.BlobContext.new(
          resource: LayeredPost,
          attachment: attachment,
          operation: :attach
        )

      {:ok, blob} =
        AshStorage.BlobIO.write("layered proxy content", bctx,
          filename: "layered.txt",
          content_type: "text/plain"
        )

      assert {:ok, "layered proxy content-resource-cover"} =
               Service.Test.download(blob.key, [])

      plug_opts = Proxy.init(resource: LayeredPost, attachment: :cover_image, access: :public)
      conn = conn(:get, "/#{blob.key}") |> Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body == "layered proxy content"

      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
    end

    test "sets content-type from key extension" do
      ctx = Service.Context.new([])
      Service.Test.upload("photo.jpg", "image data", ctx)

      conn = call("/photo.jpg")
      assert conn.status == 200
      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "image/jpeg"
    end

    test "sets X-Content-Type-Options: nosniff and defaults to attachment disposition" do
      ctx = Service.Context.new([])
      Service.Test.upload("page.html", "<script>alert(1)</script>", ctx)

      conn = call("/page.html")
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "a scriptable type is forced to attachment even when the mount allows documents" do
      ctx = Service.Context.new([])
      Service.Test.upload("page.html", "<script>alert(1)</script>", ctx)

      # text/html is in no inline policy, so ?disposition=inline cannot widen it.
      conn = call("/page.html?disposition=inline", inline: :documents)

      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      refute disposition =~ "inline"
    end

    test "an allowlisted type renders inline by default (no query param)" do
      ctx = Service.Context.new([])
      Service.Test.upload("photo.png", "image data", ctx)

      conn = call("/photo.png", inline: :images)

      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
    end

    test "?disposition=attachment forces download even for an allowlisted type" do
      ctx = Service.Context.new([])
      Service.Test.upload("photo.png", "image data", ctx)

      conn = call("/photo.png?disposition=attachment", inline: :images)

      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "SVG is never inline, even under an images policy" do
      ctx = Service.Context.new([])
      Service.Test.upload("logo.svg", "<svg onload=\"alert(1)\"/>", ctx)

      conn = call("/logo.svg", inline: :images)

      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "uses blob filename extension when stored content-type is generic" do
      {:ok, attachment} = AshStorage.Info.attachment(LayeredPost, :cover_image)

      bctx =
        AshStorage.BlobIO.BlobContext.new(
          resource: LayeredPost,
          attachment: attachment,
          operation: :attach
        )

      {:ok, blob} =
        AshStorage.BlobIO.write("pdf content", bctx,
          filename: "report.pdf",
          content_type: "application/octet-stream"
        )

      plug_opts = Proxy.init(resource: LayeredPost, attachment: :cover_image, access: :public)
      conn = conn(:get, "/#{blob.key}") |> Proxy.call(plug_opts)

      assert conn.status == 200

      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"
    end

    test "sets inline content-disposition with sanitized filename" do
      ctx = Service.Context.new([])
      Service.Test.upload("documents/file.pdf", "pdf content", ctx)

      # application/pdf is in the :documents inline policy, so it renders inline;
      # the filename query param is sanitized for the header.
      conn = call(~s(/documents/file.pdf?filename=report"bad.pdf), inline: :documents)
      assert conn.status == 200

      [content_disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert content_disposition == ~s(inline; filename="report_bad.pdf")
    end

    test "uses blob filename as content-type hint for encrypted keys" do
      {:ok, attachment} = AshStorage.Info.attachment(LayeredPost, :cover_image)

      filename = "2024-04 Labs Lipid.pdf"

      bctx =
        AshStorage.BlobIO.BlobContext.new(
          resource: LayeredPost,
          attachment: attachment,
          operation: :attach
        )

      {:ok, blob} =
        AshStorage.BlobIO.write("pdf content", bctx,
          key: "documents/file.enc",
          filename: filename,
          content_type: "application/octet-stream"
        )

      plug_opts =
        Proxy.init(
          resource: LayeredPost,
          attachment: :cover_image,
          access: :public,
          inline: :documents
        )

      conn =
        conn(:get, "/#{blob.key}?disposition=inline&filename=#{URI.encode_www_form(filename)}")
        |> Proxy.call(plug_opts)

      assert conn.status == 200

      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "application/pdf"

      [content_disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert content_disposition == ~s(inline; filename="#{filename}")
    end

    test "does not use signed filename as content-type hint for key-only proxying" do
      ctx = Service.Context.new([])
      Service.Test.upload("documents/file.enc", "pdf content", ctx)

      filename = "2024-04 Labs Lipid.pdf"
      conn = call("/documents/file.enc?filename=#{URI.encode_www_form(filename)}")

      assert conn.status == 200

      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      refute content_type =~ "application/pdf"
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

    test "rejects legacy secret requests without token" do
      ctx = Service.Context.new([])
      Service.Test.upload("secret.txt", "secret data", ctx)

      conn = call("/secret.txt", secret: @secret)
      assert conn.status == 403
    end

    test "serves file with valid legacy secret token" do
      ctx = Service.Context.new([])
      Service.Test.upload("secret.txt", "secret data", ctx)

      expires = System.system_time(:second) + 3600
      token = AshStorage.Token.sign(@secret, "secret.txt", expires)

      plug_opts =
        Proxy.init(
          service: {Service.Test, []},
          secret: @secret
        )

      conn =
        conn(:get, "/secret.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body == "secret data"
      # Signed (token-bearing) responses must not be cached by intermediaries.
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store, private"]
    end

    test "serves file with explicit signed access token" do
      ctx = Service.Context.new([])
      Service.Test.upload("secret.txt", "secret data", ctx)

      expires = System.system_time(:second) + 3600
      token = AshStorage.Token.sign(@secret, "secret.txt", expires)

      plug_opts =
        Proxy.init(
          service: {Service.Test, []},
          access: {:signed, secret: @secret}
        )

      conn =
        conn(:get, "/secret.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body == "secret data"
      # Signed (token-bearing) responses must not be cached by intermediaries.
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store, private"]
    end

    test "rejects configs with both access and a bare secret" do
      assert_raise ArgumentError, ~r/pass either :access or :secret/, fn ->
        Proxy.init(
          service: {Service.Test, []},
          access: :public,
          secret: @secret
        )
      end
    end

    test "rejects unsupported access modes" do
      assert_raise ArgumentError, ~r/invalid AshStorage.Plug.Proxy :access value/, fn ->
        Proxy.init(
          service: {Service.Test, []},
          access: {:authorize, __MODULE__}
        )
      end
    end

    test "rejects signed URLs whose remaining lifetime exceeds :max_lifetime_seconds" do
      ctx = Service.Context.new([])
      Service.Test.upload("secret.txt", "secret data", ctx)

      # 1-hour token presented against a 5-minute cap → rejected.
      expires = System.system_time(:second) + 3600
      token = AshStorage.Token.sign(@secret, "secret.txt", expires)

      plug_opts =
        Proxy.init(
          service: {Service.Test, []},
          access: {:signed, secret: @secret},
          max_lifetime_seconds: 300
        )

      conn =
        conn(:get, "/secret.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> Proxy.call(plug_opts)

      assert conn.status == 403
    end

    test "accepts signed URLs whose remaining lifetime is within :max_lifetime_seconds" do
      ctx = Service.Context.new([])
      Service.Test.upload("secret.txt", "secret data", ctx)

      # Token expires in 60 s, cap is 300 s → accepted.
      expires = System.system_time(:second) + 60
      token = AshStorage.Token.sign(@secret, "secret.txt", expires)

      plug_opts =
        Proxy.init(
          service: {Service.Test, []},
          access: {:signed, secret: @secret},
          max_lifetime_seconds: 300
        )

      conn =
        conn(:get, "/secret.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body == "secret data"
    end

    test "rejects :max_lifetime_seconds with a non-positive value" do
      assert_raise ArgumentError, ~r/:max_lifetime_seconds must be a positive integer/, fn ->
        Proxy.init(
          service: {Service.Test, []},
          max_lifetime_seconds: 0
        )
      end

      assert_raise ArgumentError, ~r/:max_lifetime_seconds must be a positive integer/, fn ->
        Proxy.init(
          service: {Service.Test, []},
          max_lifetime_seconds: "300"
        )
      end
    end
  end

  describe ":actor_assign" do
    defmodule ActorEchoLayer do
      # A test-only layer that emits the actor it saw in bctx into the
      # response body. Lets the test assert "yes the proxy threaded an
      # actor through" without depending on any encryption machinery.
      @behaviour AshStorage.Layer

      @impl true
      def default_metadata_key(_opts), do: "actor-echo"

      @impl true
      def read(read, _opts) do
        actor = read.blob_context && read.blob_context.actor
        {:ok, %{read | data: read.data <> "|actor=#{inspect(actor)}"}}
      end
    end

    test "threads conn.assigns[:current_user] into BlobContext.actor when configured" do
      ctx = Service.Context.new([])
      Service.Test.upload("doc.txt", "body", ctx)

      plug_opts =
        Proxy.init(
          service: {Service.Test, []},
          layers: [ActorEchoLayer],
          actor_assign: :current_user
        )

      conn =
        conn(:get, "/doc.txt")
        |> Plug.Conn.assign(:current_user, %{id: "u-1"})
        |> Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~s|actor=%{id: "u-1"}|
    end

    test "accepts a 1-arity function and uses its return as the actor" do
      ctx = Service.Context.new([])
      Service.Test.upload("doc.txt", "body", ctx)

      plug_opts =
        Proxy.init(
          service: {Service.Test, []},
          layers: [ActorEchoLayer],
          actor_assign: fn conn -> Map.get(conn.assigns, :custom_actor) end
        )

      conn =
        conn(:get, "/doc.txt")
        |> Plug.Conn.assign(:custom_actor, %{id: "u-fn"})
        |> Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body =~ ~s|actor=%{id: "u-fn"}|
    end

    test "leaves bctx.actor as nil when :actor_assign is not configured (legacy behaviour)" do
      ctx = Service.Context.new([])
      Service.Test.upload("doc.txt", "body", ctx)

      plug_opts = Proxy.init(service: {Service.Test, []}, layers: [ActorEchoLayer])

      conn =
        conn(:get, "/doc.txt")
        |> Plug.Conn.assign(:current_user, %{id: "ignored"})
        |> Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body =~ "actor=nil"
    end

    test "rejects :actor_assign values that are not atom or 1-arity function" do
      assert_raise ArgumentError, ~r/:actor_assign must be/, fn ->
        Proxy.init(service: {Service.Test, []}, actor_assign: "current_user")
      end

      assert_raise ArgumentError, ~r/:actor_assign must be/, fn ->
        Proxy.init(service: {Service.Test, []}, actor_assign: fn -> :no_arg end)
      end
    end
  end
end
