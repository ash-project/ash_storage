defmodule AshStorage.BlobIO.SupportTest do
  use ExUnit.Case, async: true

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.Operation.{BlobDraft, ServiceState}
  alias AshStorage.BlobIO.Support

  defp operation(extra) do
    Map.merge(
      %{
        blob_context: BlobContext.new(operation: :write),
        service: ServiceState.new(AshStorage.Service.Test, [])
      },
      extra
    )
  end

  describe "put_service_context/1 blob metadata" do
    test "forwards the write draft's content_type and filename to the service context" do
      result =
        operation(%{draft: %BlobDraft{content_type: "image/png", filename: "cover.png"}})
        |> Support.put_service_context()

      assert result.service.context.content_type == "image/png"
      assert result.service.context.filename == "cover.png"
    end

    test "falls back to the persisted blob's content_type/filename when there is no draft" do
      result =
        operation(%{blob: %{content_type: "text/plain", filename: "notes.txt"}})
        |> Support.put_service_context()

      assert result.service.context.content_type == "text/plain"
      assert result.service.context.filename == "notes.txt"
    end

    test "leaves them nil when neither draft nor blob supplies them" do
      result = Support.put_service_context(operation(%{}))

      assert result.service.context.content_type == nil
      assert result.service.context.filename == nil
    end
  end

  describe "validate_key/1" do
    test "accepts a relative, traversal-free key" do
      assert :ok = Support.validate_key("acme/avatars/9f2c")
    end

    test "rejects an empty key" do
      assert {:error, :empty_storage_key} = Support.validate_key("")
    end

    test "rejects a key that escapes its root" do
      assert {:error, {:unsafe_storage_key, "../etc/passwd"}} =
               Support.validate_key("../etc/passwd")
    end

    test "rejects an absolute key" do
      assert {:error, {:unsafe_storage_key, "/etc/passwd"}} =
               Support.validate_key("/etc/passwd")
    end

    test "rejects a non-binary key" do
      assert {:error, {:invalid_storage_key, nil}} = Support.validate_key(nil)
    end
  end
end
