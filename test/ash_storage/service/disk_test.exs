defmodule AshStorage.Service.DiskTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.Context
  alias AshStorage.Service.Disk

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    ctx = Context.new(root: tmp_dir, base_url: "http://localhost:4000/storage")
    {:ok, ctx: ctx, root: tmp_dir}
  end

  describe "upload/3" do
    test "uploads binary data", %{ctx: ctx, root: root} do
      assert :ok = Disk.upload("test.txt", "hello world", ctx)
      assert File.read!(Path.join(root, "test.txt")) == "hello world"
    end

    test "uploads iolist data", %{ctx: ctx, root: root} do
      assert :ok = Disk.upload("test.txt", ["hello", " ", "world"], ctx)
      assert File.read!(Path.join(root, "test.txt")) == "hello world"
    end

    test "uploads file stream", %{ctx: ctx, root: root} do
      source = Path.join(root, "source.txt")
      File.write!(source, "streamed content")

      assert :ok = Disk.upload("dest.txt", File.stream!(source), ctx)
      assert File.read!(Path.join(root, "dest.txt")) == "streamed content"
    end

    test "creates nested directories as needed", %{ctx: ctx, root: root} do
      assert :ok = Disk.upload("a/b/c/test.txt", "nested", ctx)
      assert File.read!(Path.join(root, "a/b/c/test.txt")) == "nested"
    end
  end

  describe "path traversal" do
    test "rejects keys that escape the root on every op", %{ctx: ctx, root: root} do
      # Plant a sentinel just outside the root that a traversal would try to reach.
      outside = Path.join(Path.dirname(root), "escaped_secret.txt")
      File.write!(outside, "TOP SECRET")
      on_exit(fn -> File.rm_rf!(outside) end)

      for key <- ["../escaped_secret.txt", "../../etc/passwd", "a/../../escaped_secret.txt",
                  "/etc/passwd"] do
        assert {:error, {:unsafe_storage_key, ^key}} = Disk.download(key, ctx)
        assert {:error, {:unsafe_storage_key, ^key}} = Disk.upload(key, "x", ctx)
        assert {:error, {:unsafe_storage_key, ^key}} = Disk.delete(key, ctx)
      end

      # The traversing uploads never escaped the root.
      assert File.read!(outside) == "TOP SECRET"
    end

    test "rejects a symlink under root that points outside it", %{ctx: ctx, root: root} do
      # Lexical traversal is blocked above; this covers the symlink-vs-root gap
      # that 1-arity Path.safe_relative (containment vs CWD) would have missed.
      outside = Path.join(Path.dirname(root), "symlink_secret.txt")
      File.write!(outside, "TOP SECRET")
      on_exit(fn -> File.rm_rf!(outside) end)

      File.ln_s!(outside, Path.join(root, "link.txt"))

      assert {:error, {:unsafe_storage_key, "link.txt"}} = Disk.download("link.txt", ctx)
      assert {:error, {:unsafe_storage_key, "link.txt"}} = Disk.delete("link.txt", ctx)
      assert File.read!(outside) == "TOP SECRET"
    end
  end

  describe "permissions" do
    test "writes blobs and dirs with owner-only permissions", %{ctx: ctx, root: root} do
      assert :ok = Disk.upload("perms/secret.txt", "data", ctx)

      {:ok, file_stat} = File.stat(Path.join(root, "perms/secret.txt"))
      assert Bitwise.band(file_stat.mode, 0o777) == 0o600

      {:ok, dir_stat} = File.stat(Path.join(root, "perms"))
      assert Bitwise.band(dir_stat.mode, 0o777) == 0o700
    end
  end

  describe "download/2" do
    test "downloads an existing file", %{ctx: ctx, root: root} do
      File.write!(Path.join(root, "test.txt"), "hello")
      assert {:ok, "hello"} = Disk.download("test.txt", ctx)
    end

    test "returns error for missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Disk.download("nonexistent.txt", ctx)
    end
  end

  describe "delete/2" do
    test "deletes an existing file", %{ctx: ctx, root: root} do
      path = Path.join(root, "test.txt")
      File.write!(path, "hello")

      assert :ok = Disk.delete("test.txt", ctx)
      refute File.exists?(path)
    end

    test "returns ok for missing file", %{ctx: ctx} do
      assert :ok = Disk.delete("nonexistent.txt", ctx)
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{ctx: ctx, root: root} do
      File.write!(Path.join(root, "test.txt"), "hello")
      assert {:ok, true} = Disk.exists?("test.txt", ctx)
    end

    test "returns false for missing file", %{ctx: ctx} do
      assert {:ok, false} = Disk.exists?("nonexistent.txt", ctx)
    end
  end

  describe "url/2" do
    test "generates a URL with the base_url and key", %{ctx: ctx} do
      assert Disk.url("abc/test.txt", ctx) == "http://localhost:4000/storage/abc/test.txt"
    end

    test "appends :original_filename as a path segment", %{root: root} do
      ctx =
        Context.new(
          root: root,
          base_url: "http://localhost:4000/storage",
          original_filename: "photo.svg"
        )

      assert Disk.url("abc123", ctx) == "http://localhost:4000/storage/abc123/photo.svg"
    end

    test "omits filename segment when :original_filename is not set", %{ctx: ctx} do
      assert Disk.url("abc123", ctx) == "http://localhost:4000/storage/abc123"
    end

    test "encodes slash in :original_filename to prevent path splitting", %{root: root} do
      ctx =
        Context.new(
          root: root,
          base_url: "http://localhost:4000/storage",
          original_filename: "icons/arrow.svg"
        )

      assert Disk.url("abc123", ctx) == "http://localhost:4000/storage/abc123/icons%2Farrow.svg"
    end

    test "signed URL with :original_filename signs over storage key only", %{root: root} do
      secret = "test-secret-32bytes!!!!!!!!!!!!!!"

      ctx =
        Context.new(
          root: root,
          base_url: "http://localhost:4000/storage",
          secret: secret,
          original_filename: "photo.svg"
        )

      url = Disk.url("abc123", ctx)

      assert url =~ "http://localhost:4000/storage/abc123/photo.svg?"
      %URI{query: query} = URI.parse(url)
      params = URI.decode_query(query)
      expires_at = String.to_integer(params["expires"])
      expected_token = AshStorage.Token.sign(secret, "abc123", expires_at)
      assert Plug.Crypto.secure_compare(params["token"], expected_token)
    end
  end

  describe "direct_upload/2" do
    test "generates upload URL and headers", %{ctx: ctx} do
      assert {:ok, %{url: url, headers: headers}} = Disk.direct_upload("my-key", ctx)
      assert url == "http://localhost:4000/storage/disk/my-key"
      assert headers["content-type"] == "application/octet-stream"
    end

    test "uses provided content_type", %{root: root} do
      ctx =
        Context.new(
          root: root,
          base_url: "http://localhost:4000/storage",
          content_type: "image/png"
        )

      assert {:ok, %{headers: headers}} = Disk.direct_upload("my-key", ctx)
      assert headers["content-type"] == "image/png"
    end
  end

  describe "upload then download round-trip" do
    test "binary data survives round-trip", %{ctx: ctx} do
      content = :crypto.strong_rand_bytes(1024)
      key = "round-trip-#{System.unique_integer([:positive])}"

      assert :ok = Disk.upload(key, content, ctx)
      assert {:ok, ^content} = Disk.download(key, ctx)
    end
  end
end
