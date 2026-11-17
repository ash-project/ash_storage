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

  describe "download/2" do
    test "downloads an existing file", %{ctx: ctx, root: root} do
      File.write!(Path.join(root, "test.txt"), "hello")
      assert {:ok, "hello"} = Disk.download("test.txt", ctx)
    end

    test "returns error for missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Disk.download("nonexistent.txt", ctx)
    end
  end

  describe "stream_download/2" do
    test "streams an existing file in chunks", %{ctx: ctx, root: root} do
      content = :crypto.strong_rand_bytes(200_000)
      File.write!(Path.join(root, "big.bin"), content)

      assert {:ok, stream} = Disk.stream_download("big.bin", ctx)
      assert %File.Stream{} = stream
      chunks = Enum.to_list(stream)
      assert length(chunks) > 1
      assert Enum.all?(chunks, &(byte_size(&1) <= 65_536))
      assert IO.iodata_to_binary(chunks) == content
    end

    test "honors the :chunk_size service opt", %{root: root} do
      ctx = Context.new(root: root, base_url: "http://localhost:4000/storage", chunk_size: 4)
      File.write!(Path.join(root, "test.txt"), "hello world")

      assert {:ok, stream} = Disk.stream_download("test.txt", ctx)
      assert Enum.to_list(stream) == ["hell", "o wo", "rld"]
    end

    test "yields no chunks for an empty file", %{ctx: ctx, root: root} do
      File.write!(Path.join(root, "empty.txt"), "")

      assert {:ok, stream} = Disk.stream_download("empty.txt", ctx)
      assert Enum.to_list(stream) == []
    end

    test "returns not_found for a missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Disk.stream_download("nonexistent.txt", ctx)
    end

    test "returns eisdir for a directory key, matching download/2", %{ctx: ctx, root: root} do
      File.mkdir_p!(Path.join(root, "a"))
      assert {:error, :eisdir} = Disk.stream_download("a", ctx)
      assert {:error, :eisdir} = Disk.download("a", ctx)
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

  describe "unsafe keys" do
    # The service root is a subdirectory of tmp_dir, so every escape target
    # stays inside this test's tmp_dir.
    setup %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      File.mkdir_p!(root)

      outside = Path.join(tmp_dir, "outside.txt")
      File.write!(outside, "secret")

      # A symlink inside the root that points back out of it
      File.ln_s!(tmp_dir, Path.join(root, "escape"))

      ctx = Context.new(root: root, base_url: "http://localhost:4000/storage")
      {:ok, ctx: ctx, root: root, outside: outside}
    end

    test "upload/3 rejects them without writing outside the root", %{
      ctx: ctx,
      outside: outside,
      tmp_dir: tmp_dir
    } do
      for key <- unsafe_keys(outside) do
        assert {:error, :einval} = Disk.upload(key, "overwritten", ctx), "key: #{key}"
      end

      assert File.read!(outside) == "secret"

      assert {:error, :einval} = Disk.upload("../new_dir/file.txt", "data", ctx)
      refute File.exists?(Path.join(tmp_dir, "new_dir"))
    end

    test "download/2 rejects them", %{ctx: ctx, outside: outside} do
      for key <- unsafe_keys(outside) do
        assert {:error, :einval} = Disk.download(key, ctx), "key: #{key}"
      end
    end

    test "stream_download/2 rejects them", %{ctx: ctx, outside: outside} do
      for key <- unsafe_keys(outside) do
        assert {:error, :einval} = Disk.stream_download(key, ctx), "key: #{key}"
      end
    end

    test "head/2 rejects them", %{ctx: ctx, outside: outside} do
      for key <- unsafe_keys(outside) do
        assert {:error, :einval} = Disk.head(key, ctx), "key: #{key}"
      end
    end

    test "delete/2 rejects them without deleting outside the root", %{
      ctx: ctx,
      outside: outside
    } do
      for key <- unsafe_keys(outside) do
        assert {:error, :einval} = Disk.delete(key, ctx), "key: #{key}"
      end

      assert File.exists?(outside)
    end

    test "exists?/2 rejects them", %{ctx: ctx, outside: outside} do
      for key <- unsafe_keys(outside) do
        assert {:error, :einval} = Disk.exists?(key, ctx), "key: #{key}"
      end
    end

    test "keys with .. that stay inside the root are allowed", %{ctx: ctx, root: root} do
      assert :ok = Disk.upload("a/../inside.txt", "hello", ctx)
      assert File.read!(Path.join(root, "inside.txt")) == "hello"
      assert {:ok, "hello"} = Disk.download("b/../inside.txt", ctx)
    end
  end

  # Keys that resolve to `outside`, which sits next to the service root
  defp unsafe_keys(outside) do
    [
      "../outside.txt",
      "nested/../../outside.txt",
      "escape/outside.txt",
      outside
    ]
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
