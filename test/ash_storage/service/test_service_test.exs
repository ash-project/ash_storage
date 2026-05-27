defmodule AshStorage.Service.TestServiceTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.Context
  alias AshStorage.Service.Test, as: TestService

  # Use a unique table name per test module to allow async
  @table :"#{__MODULE__}"

  setup do
    TestService.start(name: @table)
    TestService.reset!(name: @table)
    ctx = Context.new(name: @table)
    {:ok, ctx: ctx}
  end

  describe "upload/3 and download/2" do
    test "stores and retrieves binary data", %{ctx: ctx} do
      assert :ok = TestService.upload("file.txt", "hello", ctx)
      assert {:ok, %{body: "hello"}} = TestService.download("file.txt", ctx)
    end

    test "stores and retrieves iolist data", %{ctx: ctx} do
      assert :ok = TestService.upload("file.txt", ["hello", " ", "world"], ctx)
      assert {:ok, %{body: "hello world"}} = TestService.download("file.txt", ctx)
    end

    test "returns not_found for missing key", %{ctx: ctx} do
      assert {:error, :not_found} = TestService.download("missing", ctx)
    end

    test "overwrites existing key", %{ctx: ctx} do
      TestService.upload("key", "first", ctx)
      TestService.upload("key", "second", ctx)
      assert {:ok, %{body: "second"}} = TestService.download("key", ctx)
    end
  end

  describe "delete/2" do
    test "removes a stored file", %{ctx: ctx} do
      TestService.upload("file.txt", "data", ctx)
      assert :ok = TestService.delete("file.txt", ctx)
      assert {:error, :not_found} = TestService.download("file.txt", ctx)
    end

    test "succeeds for missing key", %{ctx: ctx} do
      assert :ok = TestService.delete("missing", ctx)
    end
  end

  describe "exists?/2" do
    test "returns true for stored file", %{ctx: ctx} do
      TestService.upload("file.txt", "data", ctx)
      assert {:ok, true} = TestService.exists?("file.txt", ctx)
    end

    test "returns false for missing file", %{ctx: ctx} do
      assert {:ok, false} = TestService.exists?("missing", ctx)
    end
  end

  describe "list_keys/1" do
    test "returns all stored keys" do
      opts = [name: @table]
      TestService.upload("a.txt", "1", Context.new(opts))
      TestService.upload("b.txt", "2", Context.new(opts))
      TestService.upload("c.txt", "3", Context.new(opts))

      keys = TestService.list_keys(opts)
      assert Enum.sort(keys) == ["a.txt", "b.txt", "c.txt"]
    end

    test "returns empty list when nothing stored" do
      assert TestService.list_keys(name: @table) == []
    end
  end

  describe "reset!/1" do
    test "clears all stored files", %{ctx: ctx} do
      TestService.upload("a.txt", "1", ctx)
      TestService.upload("b.txt", "2", ctx)
      TestService.reset!(name: @table)

      assert TestService.list_keys(name: @table) == []
    end
  end

  describe "url/2" do
    test "generates a URL with default base", %{ctx: ctx} do
      assert TestService.url("my-key", ctx) == "http://test.local/storage/my-key"
    end

    test "generates a URL with custom base_url" do
      ctx = Context.new(name: @table, base_url: "http://cdn.example.com")
      assert TestService.url("my-key", ctx) == "http://cdn.example.com/my-key"
    end
  end

  describe "content_type round-trip" do
    test "stores ctx.content_type alongside the bytes", %{ctx: ctx} do
      ctx = Context.put_content_type(ctx, "image/svg+xml")
      TestService.upload("logo", "<svg/>", ctx)

      assert TestService.get_content_type("logo", name: @table) == "image/svg+xml"
    end

    test "ctx.content_type wins over service_opts[:content_type]" do
      ctx =
        Context.new(name: @table, content_type: "image/jpeg")
        |> Context.put_content_type("image/png")

      TestService.upload("photo", "data", ctx)

      assert TestService.get_content_type("photo", name: @table) == "image/png"
    end

    test "download returns the stored content_type", %{ctx: ctx} do
      ctx = Context.put_content_type(ctx, "image/svg+xml")
      TestService.upload("logo", "<svg/>", ctx)

      assert {:ok, %{body: "<svg/>", content_type: "image/svg+xml"}} =
               TestService.download("logo", ctx)
    end

    test "content_type is nil when nothing was set", %{ctx: ctx} do
      TestService.upload("plain", "data", ctx)
      assert TestService.get_content_type("plain", name: @table) == nil

      assert {:ok, %{content_type: nil}} = TestService.download("plain", ctx)
    end
  end

  describe "direct_upload/2" do
    test "generates upload URL and headers", %{ctx: ctx} do
      assert {:ok, %{url: url, headers: headers}} = TestService.direct_upload("my-key", ctx)
      assert url == "http://test.local/storage/direct/my-key"
      assert headers["content-type"] == "application/octet-stream"
    end

    test "uses provided content_type" do
      ctx = Context.new(name: @table, content_type: "image/png")
      assert {:ok, %{headers: headers}} = TestService.direct_upload("my-key", ctx)
      assert headers["content-type"] == "image/png"
    end
  end

  describe "round-trip" do
    test "binary data survives round-trip", %{ctx: ctx} do
      content = :crypto.strong_rand_bytes(1024)
      assert :ok = TestService.upload("random", content, ctx)
      assert {:ok, %{body: ^content}} = TestService.download("random", ctx)
    end
  end

  describe "auto-start" do
    test "auto-creates table on first upload" do
      table = :"auto_start_#{System.unique_integer([:positive])}"
      ctx = Context.new(name: table)

      # Don't call start — should auto-create
      assert :ok = TestService.upload("key", "data", ctx)
      assert {:ok, %{body: "data"}} = TestService.download("key", ctx)

      :ets.delete(table)
    end
  end

  describe "convenience helpers" do
    test "exists?/2 works with keyword opts", %{ctx: ctx} do
      TestService.upload("file.txt", "data", ctx)
      assert TestService.exists?("file.txt", name: @table)
    end

    test "download/2 works with keyword opts", %{ctx: ctx} do
      TestService.upload("file.txt", "data", ctx)
      assert {:ok, "data"} = TestService.download("file.txt", name: @table)
    end
  end
end
