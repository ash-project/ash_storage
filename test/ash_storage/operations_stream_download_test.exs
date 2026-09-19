defmodule AshStorage.OperationsStreamDownloadTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Service.Context
  alias AshStorage.Service.Test, as: TestService

  setup do
    TestService.reset!()
    :ok
  end

  defp create_post! do
    AshStorage.Test.Post
    |> Ash.Changeset.for_create(:create, %{title: "p"})
    |> Ash.create!()
  end

  defp attach!(data \\ "hello world") do
    {:ok, %{blob: blob}} =
      Operations.attach(create_post!(), :cover_image, data,
        filename: "f.txt",
        content_type: "text/plain"
      )

    blob
  end

  defp collect(enum), do: enum |> Enum.to_list() |> IO.iodata_to_binary()

  describe "stream_download_from_service/3" do
    test "falls back to download/2 for a service without stream_download/2" do
      ctx = Context.new([])
      key = "stream-fallback-#{System.unique_integer([:positive])}"

      :ok = TestService.upload(key, "hello world", ctx)

      refute Code.ensure_loaded?(TestService) and
               function_exported?(TestService, :stream_download, 2)

      assert {:ok, enum} = Operations.stream_download_from_service(TestService, ctx, key)
      assert collect(enum) == "hello world"
    end

    test "propagates errors from the fallback download/2" do
      ctx = Context.new([])

      assert {:error, :not_found} =
               Operations.stream_download_from_service(TestService, ctx, "missing")
    end

    test "yields no chunks for an empty body on the fallback path" do
      ctx = Context.new([])
      key = "stream-empty-#{System.unique_integer([:positive])}"

      :ok = TestService.upload(key, "", ctx)

      assert {:ok, enum} = Operations.stream_download_from_service(TestService, ctx, key)
      assert Enum.to_list(enum) == []
    end

    test "ignores a caller-supplied :expected_md5 on the fallback path" do
      ctx = Context.new([]) |> Context.put_expected_md5("not-the-real-md5")
      key = "stream-md5-#{System.unique_integer([:positive])}"

      :ok = TestService.upload(key, "hello world", ctx)

      assert {:ok, enum} = Operations.stream_download_from_service(TestService, ctx, key)
      assert collect(enum) == "hello world"
    end

    @tag :tmp_dir
    test "dispatches to the service implementation when it exists", %{tmp_dir: tmp_dir} do
      ctx = Context.new(root: tmp_dir, base_url: "/files")
      File.write!(Path.join(tmp_dir, "big.bin"), "streamed bytes")

      assert {:ok, stream} =
               Operations.stream_download_from_service(AshStorage.Service.Disk, ctx, "big.bin")

      assert %File.Stream{} = stream
      assert collect(stream) == "streamed bytes"
    end
  end

  describe "stream_download/2" do
    test "streams a blob's bytes" do
      blob = attach!()
      assert {:ok, enum} = Operations.stream_download(blob)
      assert collect(enum) == "hello world"
    end

    test "propagates not_found from the service" do
      blob = attach!() |> Map.put(:key, "does/not/exist")
      assert {:error, :not_found} = Operations.stream_download(blob)
    end

    test "does not checksum-verify, unlike download/2" do
      blob = attach!()
      TestService.upload(blob.key, "tampered", Context.new([]))

      assert {:error, :checksum_mismatch} = Operations.download(blob)
      assert {:ok, enum} = Operations.stream_download(blob)
      assert collect(enum) == "tampered"
    end
  end
end
