defmodule AshStorage.OperationsDownloadTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations
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

  test "downloads and verifies when blob.checksum matches stored bytes" do
    blob = attach!()
    assert {:ok, "hello world"} = Operations.download(blob)
  end

  test "returns checksum_mismatch when stored bytes have been tampered with" do
    blob = attach!()
    TestService.upload(blob.key, "tampered", AshStorage.Service.Context.new([]))

    assert {:error, :checksum_mismatch} = Operations.download(blob)
  end

  test "skips verification when blob.checksum is empty" do
    blob = attach!() |> Map.put(:checksum, "")
    assert {:ok, "hello world"} = Operations.download(blob)
  end

  test "skips verification when blob.checksum is nil" do
    blob = attach!() |> Map.put(:checksum, nil)
    assert {:ok, "hello world"} = Operations.download(blob)
  end

  test "propagates not_found from the service" do
    blob = attach!() |> Map.put(:key, "does/not/exist")
    assert {:error, :not_found} = Operations.download(blob)
  end
end
