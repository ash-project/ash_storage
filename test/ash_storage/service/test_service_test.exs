defmodule AshStorage.Service.TestServiceTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.Test, as: TestService

  # Use a unique table name per test module to allow async
  @table :"#{__MODULE__}"

  setup do
    TestService.start(name: @table)
    TestService.reset!(name: @table)
    opts = [name: @table]
    {:ok, opts: opts}
  end

  describe "upload/3 and download/2" do
    test "stores and retrieves binary data", %{opts: opts} do
      assert :ok = TestService.upload("file.txt", "hello", opts)
      assert {:ok, "hello"} = TestService.download("file.txt", opts)
    end

    test "stores and retrieves iolist data", %{opts: opts} do
      assert :ok = TestService.upload("file.txt", ["hello", " ", "world"], opts)
      assert {:ok, "hello world"} = TestService.download("file.txt", opts)
    end

    test "returns not_found for missing key", %{opts: opts} do
      assert {:error, :not_found} = TestService.download("missing", opts)
    end

    test "overwrites existing key", %{opts: opts} do
      TestService.upload("key", "first", opts)
      TestService.upload("key", "second", opts)
      assert {:ok, "second"} = TestService.download("key", opts)
    end
  end

  describe "delete/2" do
    test "removes a stored file", %{opts: opts} do
      TestService.upload("file.txt", "data", opts)
      assert :ok = TestService.delete("file.txt", opts)
      assert {:error, :not_found} = TestService.download("file.txt", opts)
    end

    test "succeeds for missing key", %{opts: opts} do
      assert :ok = TestService.delete("missing", opts)
    end
  end

  describe "exists?/2" do
    test "returns true for stored file", %{opts: opts} do
      TestService.upload("file.txt", "data", opts)
      assert TestService.exists?("file.txt", opts)
    end

    test "returns false for missing file", %{opts: opts} do
      refute TestService.exists?("missing", opts)
    end
  end

  describe "list_keys/1" do
    test "returns all stored keys", %{opts: opts} do
      TestService.upload("a.txt", "1", opts)
      TestService.upload("b.txt", "2", opts)
      TestService.upload("c.txt", "3", opts)

      keys = TestService.list_keys(opts)
      assert Enum.sort(keys) == ["a.txt", "b.txt", "c.txt"]
    end

    test "returns empty list when nothing stored", %{opts: opts} do
      assert TestService.list_keys(opts) == []
    end
  end

  describe "reset!/1" do
    test "clears all stored files", %{opts: opts} do
      TestService.upload("a.txt", "1", opts)
      TestService.upload("b.txt", "2", opts)
      TestService.reset!(opts)

      assert TestService.list_keys(opts) == []
    end
  end

  describe "url/2" do
    test "generates a URL with default base", %{opts: opts} do
      assert TestService.url("my-key", opts) == "http://test.local/storage/my-key"
    end

    test "generates a URL with custom base_url", %{opts: opts} do
      opts = Keyword.put(opts, :base_url, "http://cdn.example.com")
      assert TestService.url("my-key", opts) == "http://cdn.example.com/my-key"
    end
  end

  describe "direct_upload_url/2" do
    test "generates upload URL and headers", %{opts: opts} do
      assert {:ok, %{url: url, headers: headers}} = TestService.direct_upload_url("my-key", opts)
      assert url == "http://test.local/storage/direct/my-key"
      assert headers["content-type"] == "application/octet-stream"
    end

    test "uses provided content_type", %{opts: opts} do
      opts = Keyword.put(opts, :content_type, "image/png")
      assert {:ok, %{headers: headers}} = TestService.direct_upload_url("my-key", opts)
      assert headers["content-type"] == "image/png"
    end
  end

  describe "round-trip" do
    test "binary data survives round-trip", %{opts: opts} do
      content = :crypto.strong_rand_bytes(1024)
      assert :ok = TestService.upload("random", content, opts)
      assert {:ok, ^content} = TestService.download("random", opts)
    end
  end

  describe "auto-start" do
    test "auto-creates table on first upload" do
      table = :"auto_start_#{System.unique_integer([:positive])}"
      opts = [name: table]

      # Don't call start — should auto-create
      assert :ok = TestService.upload("key", "data", opts)
      assert {:ok, "data"} = TestService.download("key", opts)

      :ets.delete(table)
    end
  end
end
