defmodule AshStorage.FileArgumentTest do
  use ExUnit.Case, async: false

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  describe "create with :file argument" do
    test "attaches file on create" do
      path = Path.join(System.tmp_dir!(), "ash_storage_create_test.txt")
      File.write!(path, "hello from create")

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "with image",
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image != nil
      assert post.cover_image.blob.filename == "ash_storage_create_test.txt"

      assert {:ok, "hello from create"} =
               AshStorage.Service.Test.download(post.cover_image.blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_create_test.txt"))
    end

    test "skips attach when argument is nil" do
      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{title: "no image"})
        |> Ash.create!()

      post = Ash.load!(post, :cover_image)
      assert post.cover_image == nil
    end
  end

  describe "update with :file argument" do
    test "attaches file on update" do
      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create, %{title: "plain post"})
        |> Ash.create!()

      path = Path.join(System.tmp_dir!(), "ash_storage_update_test.jpg")
      File.write!(path, "image bytes")

      post =
        post
        |> Ash.Changeset.for_update(:update_cover_image, %{
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.update!()

      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image.blob.filename == "ash_storage_update_test.jpg"
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_update_test.jpg"))
    end

    test "replaces existing attachment on update" do
      path1 = Path.join(System.tmp_dir!(), "ash_storage_old.txt")
      path2 = Path.join(System.tmp_dir!(), "ash_storage_new.txt")
      File.write!(path1, "old content")
      File.write!(path2, "new content")

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "will replace",
          cover_image: Ash.Type.File.from_path(path1)
        })
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)
      old_key = post.cover_image.blob.key

      post =
        post
        |> Ash.Changeset.for_update(:update_cover_image, %{
          cover_image: Ash.Type.File.from_path(path2)
        })
        |> Ash.update!()

      post = Ash.load!(post, cover_image: :blob)
      assert post.cover_image.blob.filename == "ash_storage_new.txt"

      assert {:ok, "new content"} =
               AshStorage.Service.Test.download(post.cover_image.blob.key, [])

      refute AshStorage.Service.Test.exists?(old_key)
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_old.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_new.txt"))
    end
  end

  describe "end-to-end with URL" do
    test "create, load attachment URL" do
      path = Path.join(System.tmp_dir!(), "ash_storage_url_test.png")
      File.write!(path, "png data")

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "url test",
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.create!()

      post = Ash.load!(post, :cover_image_url)
      assert post.cover_image_url =~ "http://test.local/storage/"
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_url_test.png"))
    end
  end
end
