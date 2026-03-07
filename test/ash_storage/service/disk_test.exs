defmodule AshStorage.Service.DiskTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.Disk

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    opts = [root: tmp_dir, base_url: "http://localhost:4000/storage"]
    {:ok, opts: opts, root: tmp_dir}
  end

  describe "upload/3" do
    test "uploads binary data", %{opts: opts, root: root} do
      assert :ok = Disk.upload("test.txt", "hello world", opts)
      assert File.read!(Path.join(root, "test.txt")) == "hello world"
    end

    test "uploads iolist data", %{opts: opts, root: root} do
      assert :ok = Disk.upload("test.txt", ["hello", " ", "world"], opts)
      assert File.read!(Path.join(root, "test.txt")) == "hello world"
    end

    test "uploads file stream", %{opts: opts, root: root} do
      source = Path.join(root, "source.txt")
      File.write!(source, "streamed content")

      assert :ok = Disk.upload("dest.txt", File.stream!(source), opts)
      assert File.read!(Path.join(root, "dest.txt")) == "streamed content"
    end

    test "creates nested directories as needed", %{opts: opts, root: root} do
      assert :ok = Disk.upload("a/b/c/test.txt", "nested", opts)
      assert File.read!(Path.join(root, "a/b/c/test.txt")) == "nested"
    end
  end

  describe "download/2" do
    test "downloads an existing file", %{opts: opts, root: root} do
      File.write!(Path.join(root, "test.txt"), "hello")
      assert {:ok, "hello"} = Disk.download("test.txt", opts)
    end

    test "returns error for missing file", %{opts: opts} do
      assert {:error, :not_found} = Disk.download("nonexistent.txt", opts)
    end
  end

  describe "delete/2" do
    test "deletes an existing file", %{opts: opts, root: root} do
      path = Path.join(root, "test.txt")
      File.write!(path, "hello")

      assert :ok = Disk.delete("test.txt", opts)
      refute File.exists?(path)
    end

    test "returns ok for missing file", %{opts: opts} do
      assert :ok = Disk.delete("nonexistent.txt", opts)
    end
  end

  describe "exists?/2" do
    test "returns true for existing file", %{opts: opts, root: root} do
      File.write!(Path.join(root, "test.txt"), "hello")
      assert Disk.exists?("test.txt", opts)
    end

    test "returns false for missing file", %{opts: opts} do
      refute Disk.exists?("nonexistent.txt", opts)
    end
  end

  describe "url/2" do
    test "generates a URL with the base_url and key", %{opts: opts} do
      assert Disk.url("abc/test.txt", opts) == "http://localhost:4000/storage/abc/test.txt"
    end
  end

  describe "direct_upload_url/2" do
    test "generates upload URL and headers", %{opts: opts} do
      assert {:ok, %{url: url, headers: headers}} = Disk.direct_upload_url("my-key", opts)
      assert url == "http://localhost:4000/storage/disk/my-key"
      assert headers["content-type"] == "application/octet-stream"
    end

    test "uses provided content_type", %{opts: opts} do
      opts = Keyword.put(opts, :content_type, "image/png")
      assert {:ok, %{headers: headers}} = Disk.direct_upload_url("my-key", opts)
      assert headers["content-type"] == "image/png"
    end
  end

  describe "upload then download round-trip" do
    test "binary data survives round-trip", %{opts: opts} do
      content = :crypto.strong_rand_bytes(1024)
      key = "round-trip-#{System.unique_integer([:positive])}"

      assert :ok = Disk.upload(key, content, opts)
      assert {:ok, ^content} = Disk.download(key, opts)
    end
  end

  describe "delete/1 and exists?/1 (arity-1 callbacks)" do
    test "delete/1 raises because it needs opts" do
      assert_raise ArgumentError, ~r/requires options/, fn ->
        Disk.delete("key")
      end
    end

    test "exists?/1 raises because it needs opts" do
      assert_raise ArgumentError, ~r/requires options/, fn ->
        Disk.exists?("key")
      end
    end
  end
end
