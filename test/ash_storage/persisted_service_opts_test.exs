defmodule AshStorage.PersistedServiceOptsTest do
  # Mutates application config and unloads a service module; keep it out of
  # the async pool.
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Test.{Blob, ConfigurablePost}

  @root Path.join(System.tmp_dir!(), "ash_storage_persisted_service_opts")

  setup do
    Application.put_env(:ash_storage, ConfigurablePost,
      storage: [service: {AshStorage.Service.Disk, root: @root, base_url: "/files"}]
    )

    on_exit(fn -> Application.delete_env(:ash_storage, ConfigurablePost) end)
  end

  # Under interactive code loading a module is loaded on its first call. The
  # persist step must not assume that has happened: probing with
  # function_exported?/3 alone stored an empty service_opts on the first
  # direct-upload preparation after boot (attach and variant writes upload
  # first, which loads the module).
  defp unload!(module) do
    if :code.is_loaded(module) do
      :code.soft_purge(module)
      true = :code.delete(module)
    end

    refute :code.is_loaded(module)
  end

  test "direct-upload preparation persists service opts when the service module is not loaded yet" do
    unload!(AshStorage.Service.Disk)

    assert {:ok, %{blob: blob}} =
             Operations.prepare_direct_upload(ConfigurablePost, :avatar,
               filename: "photo.jpg",
               content_type: "image/jpeg",
               byte_size: 1
             )

    assert {:ok, row} = Ash.get(Blob, blob.id)
    persisted = Map.new(row.service_opts || %{}, fn {key, value} -> {to_string(key), value} end)

    assert persisted == %{"root" => @root}
  end
end
