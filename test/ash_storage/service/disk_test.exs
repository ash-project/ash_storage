defmodule AshStorage.Service.DiskTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.Context
  alias AshStorage.Service.Disk

  @moduletag :tmp_dir

  @secret "test-secret-32bytes!!!!!!!!!!!!!!"

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

  # POSIX modes; on Windows `File.chmod/2` only toggles the read-only flag.
  if match?({:unix, _}, :os.type()) do
    describe "file modes" do
      import Bitwise

      defp mode(path), do: File.stat!(path).mode &&& 0o777

      test "a new file is readable and writable by its owner only", %{ctx: ctx, root: root} do
        assert :ok = Disk.upload("test.txt", "hello", ctx)
        assert mode(Path.join(root, "test.txt")) == 0o600
      end

      test "an iolist and a file stream get the same mode", %{ctx: ctx, root: root} do
        source = Path.join(root, "source.txt")
        File.write!(source, "streamed")

        assert :ok = Disk.upload("list.txt", ["a", "b"], ctx)
        assert :ok = Disk.upload("stream.txt", File.stream!(source), ctx)

        assert mode(Path.join(root, "list.txt")) == 0o600
        assert mode(Path.join(root, "stream.txt")) == 0o600
        assert File.read!(Path.join(root, "stream.txt")) == "streamed"
      end

      test "directories it creates are owner-only, existing ones are left alone", %{
        ctx: ctx,
        root: root
      } do
        File.mkdir!(Path.join(root, "shared"))
        File.chmod!(Path.join(root, "shared"), 0o755)
        root_mode = mode(root)

        assert :ok = Disk.upload("shared/a/b/test.txt", "nested", ctx)

        assert mode(Path.join(root, "shared/a")) == 0o700
        assert mode(Path.join(root, "shared/a/b")) == 0o700
        assert mode(Path.join(root, "shared")) == 0o755
        assert mode(root) == root_mode
      end

      test "a missing root is created owner-only", %{tmp_dir: tmp_dir} do
        root = Path.join(tmp_dir, "new/root")
        ctx = Context.new(root: root)

        assert :ok = Disk.upload("test.txt", "hello", ctx)
        assert mode(root) == 0o700
        assert mode(Path.join(tmp_dir, "new")) == 0o700
      end

      test "replacing a file tightens its mode", %{ctx: ctx, root: root} do
        path = Path.join(root, "test.txt")
        File.write!(path, "old")
        File.chmod!(path, 0o644)

        assert :ok = Disk.upload("test.txt", "new", ctx)
        assert File.read!(path) == "new"
        assert mode(path) == 0o600
      end

      test "a key that names a directory is refused and the directory keeps its mode", %{
        ctx: ctx,
        root: root
      } do
        File.mkdir!(Path.join(root, "dir"))
        File.chmod!(Path.join(root, "dir"), 0o755)

        assert {:error, :eisdir} = Disk.upload("dir", "data", ctx)
        assert mode(Path.join(root, "dir")) == 0o755
      end

      test "owner_only: false leaves the modes to the process umask", %{root: root} do
        ctx = Context.new(root: root, owner_only: false)

        # What the umask gives a file and a directory created without the option.
        File.mkdir_p!(Path.join(root, "control/dir"))
        File.write!(Path.join(root, "control/file"), "x")

        assert :ok = Disk.upload("a/b/test.txt", "hello", ctx)

        assert mode(Path.join(root, "a/b/test.txt")) == mode(Path.join(root, "control/file"))
        assert mode(Path.join(root, "a/b")) == mode(Path.join(root, "control/dir"))
      end
    end
  end

  describe "upload/3 errors" do
    test "returns the error when a directory cannot be created", %{ctx: ctx, root: root} do
      File.write!(Path.join(root, "file"), "x")
      assert {:error, reason} = Disk.upload("file/nested/test.txt", "data", ctx)
      assert reason in [:enotdir, :eexist]
    end

    test "an invalid :owner_only option raises before anything is created", %{root: root} do
      ctx = Context.new(root: root, owner_only: nil)

      assert_raise ArgumentError, ~r/invalid :owner_only option nil/, fn ->
        Disk.upload("a/test.txt", "data", ctx)
      end

      refute File.exists?(Path.join(root, "a"))
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

    test "omits the filename when none is known", %{ctx: ctx} do
      assert Disk.url("abc123", ctx) == "http://localhost:4000/storage/abc123"
    end

    test "adds the context's filename as a query parameter", %{ctx: ctx} do
      ctx = Context.put_blob_metadata(ctx, filename: "photo.svg")

      assert Disk.url("abc123", ctx) == "http://localhost:4000/storage/abc123?filename=photo.svg"
    end

    test "encodes the filename so that it round-trips", %{ctx: ctx} do
      filename = "icons/my arrow&more.svg"
      url = Disk.url("abc123", Context.put_blob_metadata(ctx, filename: filename))

      %URI{path: path, query: query} = URI.parse(url)
      assert path == "/storage/abc123"
      assert URI.decode_query(query) == %{"filename" => filename}
    end

    test "the :filename option wins over the context's filename", %{root: root} do
      ctx =
        Context.new([root: root, base_url: "/storage", filename: "chosen.png"],
          filename: "blob.png"
        )

      assert Disk.url("abc123", ctx) == "/storage/abc123?filename=chosen.png"
    end

    test "ignores :original_filename", %{root: root} do
      ctx = Context.new(root: root, base_url: "/storage", original_filename: "photo.svg")

      assert Disk.url("abc123", ctx) == "/storage/abc123"
    end

    test "a signed URL is <base>/<key>?token= with the key and the blob's metadata", %{
      root: root
    } do
      ctx =
        Context.new([root: root, base_url: "http://localhost:4000/storage", secret: @secret],
          filename: "photo.svg",
          content_type: "image/svg+xml"
        )

      {url, claims} = signed_claims("tenant-1/abc123", ctx)

      assert url =~ ~r{\Ahttp://localhost:4000/storage/tenant-1/abc123\?token=v1\.[^&]+\z}

      assert %{"s" => "tenant-1/abc123", "f" => "photo.svg", "t" => "image/svg+xml"} = claims
      refute Map.has_key?(claims, "d")
      assert claims["e"] - claims["i"] == 3600
    end

    test "service options win over the context for a signed URL", %{root: root} do
      ctx =
        Context.new(
          [
            root: root,
            base_url: "/storage",
            secret: @secret,
            filename: "chosen.png",
            content_type: "image/png",
            disposition: "attachment",
            expires_in: 60
          ],
          filename: "blob.svg",
          content_type: "image/svg+xml"
        )

      {_url, claims} = signed_claims("k", ctx)

      assert %{"f" => "chosen.png", "t" => "image/png", "d" => "attachment"} = claims
      assert claims["e"] - claims["i"] == 60
    end

    test "a list secret signs with its first entry", %{root: root} do
      ctx = Context.new(root: root, base_url: "/storage", secret: [@secret, "old-secret"])

      %URI{query: query} = URI.parse(Disk.url("k", ctx))
      token = URI.decode_query(query)["token"]

      assert {:ok, _} = AshStorage.Token.verify(token, @secret, purpose: :download)
      assert {:error, :invalid} = AshStorage.Token.verify(token, "old-secret", purpose: :download)
    end

    test "an MFA secret is resolved on every call", %{root: root} do
      ctx = Context.new(root: root, base_url: "/storage", secret: {__MODULE__, :secret, []})

      Process.put(:disk_test_secret, @secret)
      assert {_url, %{"s" => "k"}} = signed_claims("k", ctx)

      Process.put(:disk_test_secret, "rotated-secret")
      %URI{query: query} = URI.parse(Disk.url("k", ctx))
      token = URI.decode_query(query)["token"]
      assert {:ok, _} = AshStorage.Token.verify(token, "rotated-secret", purpose: :download)
    end
  end

  def secret, do: Process.get(:disk_test_secret)

  defp signed_claims(key, ctx) do
    url = Disk.url(key, ctx)
    %URI{query: query} = URI.parse(url)
    params = URI.decode_query(query)
    assert Map.keys(params) == ["token"]

    {:ok, claims} =
      AshStorage.Token.verify(params["token"], ctx.service_opts[:secret], purpose: :download)

    {url, claims}
  end

  describe "file_path/2" do
    test "returns the path of a regular file", %{ctx: ctx, root: root} do
      File.mkdir_p!(Path.join(root, "a"))
      File.write!(Path.join(root, "a/test.txt"), "hello")

      assert {:ok, path} = Disk.file_path("a/test.txt", ctx)
      assert File.read!(path) == "hello"
    end

    test "returns not_found for a missing file", %{ctx: ctx} do
      assert {:error, :not_found} = Disk.file_path("nonexistent.txt", ctx)
    end

    test "returns eisdir for a directory", %{ctx: ctx, root: root} do
      File.mkdir_p!(Path.join(root, "a"))
      assert {:error, :eisdir} = Disk.file_path("a", ctx)
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

    test "file_path/2 rejects them", %{ctx: ctx, outside: outside} do
      for key <- unsafe_keys(outside) do
        assert {:error, :einval} = Disk.file_path(key, ctx), "key: #{key}"
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
