defmodule AshStorage.ServiceConfigChangeTest do
  # Mutates application config; keep it out of the async pool.
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Test.{Blob, ConfigurablePost}

  @root Path.join(System.tmp_dir!(), "ash_storage_service_config_change")
  @old_root Path.join(@root, "old")
  @new_root Path.join(@root, "new")

  setup do
    File.rm_rf!(@root)

    on_exit(fn ->
      Application.delete_env(:ash_storage, ConfigurablePost)
      File.rm_rf!(@root)
    end)
  end

  defp use_root(root) do
    Application.put_env(:ash_storage, ConfigurablePost,
      storage: [service: {AshStorage.Service.Disk, root: root, base_url: "/files"}]
    )
  end

  # A post whose avatar was uploaded while files went to the old root, after
  # which the configured service moved to the new root.
  defp post_with_avatar_in_old_root do
    use_root(@old_root)

    post =
      ConfigurablePost
      |> Ash.Changeset.for_create(:create, %{title: "spring sale"})
      |> Ash.create!()

    {:ok, %{blob: blob, record: post}} =
      Operations.attach(post, :avatar, "old avatar", filename: "old.jpg")

    assert File.exists?(Path.join(@old_root, blob.key))

    use_root(@new_root)
    {post, blob}
  end

  test "purge deletes the file from the blob's service" do
    {post, blob} = post_with_avatar_in_old_root()

    assert {:ok, _} = Operations.purge(post, :avatar)

    refute File.exists?(Path.join(@old_root, blob.key))
    assert {:error, _} = Ash.get(Blob, blob.id)
  end

  test "replacing via attach deletes the old file from the blob's service" do
    {post, blob} = post_with_avatar_in_old_root()

    {:ok, %{blob: new_blob}} = Operations.attach(post, :avatar, "new avatar", filename: "new.jpg")

    refute File.exists?(Path.join(@old_root, blob.key))
    assert File.exists?(Path.join(@new_root, new_blob.key))
  end

  test "replacing via AttachBlob deletes the old file from the blob's service" do
    {post, blob} = post_with_avatar_in_old_root()

    {:ok, %{blob: new_blob}} =
      Operations.prepare_direct_upload(ConfigurablePost, :avatar, filename: "new.jpg")

    AshStorage.Service.Disk.upload(
      new_blob.key,
      "new avatar",
      AshStorage.Service.Context.new(root: @new_root)
    )

    post
    |> Ash.Changeset.for_update(:attach_avatar_blob, %{avatar_blob_id: new_blob.id})
    |> Ash.update!()

    refute File.exists?(Path.join(@old_root, blob.key))
    assert File.exists?(Path.join(@new_root, new_blob.key))
  end

  test "replacing via a file argument deletes the old file from the blob's service" do
    {post, blob} = post_with_avatar_in_old_root()

    path = Path.join(@root, "new.jpg")
    File.write!(path, "new avatar")

    post
    |> Ash.Changeset.for_update(:update_avatar_file, %{avatar_file: Ash.Type.File.from_path(path)})
    |> Ash.update!()

    refute File.exists?(Path.join(@old_root, blob.key))
  end
end
