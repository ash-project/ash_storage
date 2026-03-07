defmodule AshStorage.Plug.DiskServeTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AshStorage.Plug.DiskServe

  @root Path.join(
          System.tmp_dir!(),
          "ash_storage_disk_serve_test_#{System.unique_integer([:positive])}"
        )

  setup_all do
    File.mkdir_p!(@root)
    File.write!(Path.join(@root, "hello.txt"), "hello world")

    subdir = Path.join(@root, "sub/dir")
    File.mkdir_p!(subdir)
    File.write!(Path.join(subdir, "nested.txt"), "nested content")

    on_exit(fn -> File.rm_rf!(@root) end)
    :ok
  end

  defp call(path, opts \\ []) do
    plug_opts =
      DiskServe.init(Keyword.merge([root: @root], opts))

    conn(:get, path)
    |> DiskServe.call(plug_opts)
  end

  describe "serving files" do
    test "serves a file with correct content" do
      conn = call("/hello.txt")
      assert conn.status == 200
      assert conn.resp_body == "hello world"
    end

    test "sets content-type from file extension" do
      conn = call("/hello.txt")
      [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
    end

    test "serves nested files" do
      conn = call("/sub/dir/nested.txt")
      assert conn.status == 200
      assert conn.resp_body == "nested content"
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
    @secret "test-secret-32bytes!!!!!!!!!!!!!!"

    test "rejects requests without token" do
      conn = call("/hello.txt", secret: @secret)
      assert conn.status == 403
    end

    test "rejects requests with invalid token" do
      conn =
        conn(:get, "/hello.txt?token=invalid&expires=#{System.system_time(:second) + 3600}")
        |> DiskServe.call(DiskServe.init(root: @root, secret: @secret))

      assert conn.status == 403
    end

    test "rejects expired tokens" do
      expired = System.system_time(:second) - 10
      token = AshStorage.Token.sign(@secret, "hello.txt", expired)

      conn =
        conn(:get, "/hello.txt?token=#{token}&expires=#{expired}")
        |> DiskServe.call(DiskServe.init(root: @root, secret: @secret))

      assert conn.status == 403
    end

    test "serves file with valid token" do
      expires = System.system_time(:second) + 3600
      token = AshStorage.Token.sign(@secret, "hello.txt", expires)

      conn =
        conn(:get, "/hello.txt?token=#{URI.encode_www_form(token)}&expires=#{expires}")
        |> Plug.Conn.fetch_query_params()
        |> DiskServe.call(DiskServe.init(root: @root, secret: @secret))

      assert conn.status == 200
      assert conn.resp_body == "hello world"
    end
  end

  describe "content-disposition" do
    test "sets attachment disposition from query param" do
      conn =
        conn(:get, "/hello.txt?disposition=attachment")
        |> Plug.Conn.fetch_query_params()
        |> DiskServe.call(DiskServe.init(root: @root))

      assert conn.status == 200
      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition == "attachment"
    end

    test "sets attachment with filename from query param" do
      conn =
        conn(:get, "/hello.txt?disposition=attachment&filename=download.txt")
        |> Plug.Conn.fetch_query_params()
        |> DiskServe.call(DiskServe.init(root: @root))

      assert conn.status == 200
      [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition == "attachment; filename=\"download.txt\""
    end
  end
end
