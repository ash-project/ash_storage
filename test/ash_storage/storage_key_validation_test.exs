defmodule AshStorage.StorageKeyValidationTest do
  # async: false, because it uses the shared AshStorage.Service.Test store.
  use ExUnit.Case, async: false

  alias AshStorage.Operations

  alias AshStorage.Test.Blob
  alias AshStorage.Test.KeyRulesPost, as: Post
  alias AshStorage.Test.PolymorphicAttachment, as: Attachment

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp post! do
    Post
    |> Ash.Changeset.for_create(:create, %{title: "post"})
    |> Ash.create!()
  end

  # The generated blob read action requires pagination.
  defp rows(Blob), do: Ash.read!(Blob, page: [limit: 100]).results
  defp rows(resource), do: Ash.read!(resource)

  defp assert_nothing_stored do
    assert AshStorage.Service.Test.list_keys() == []
    assert rows(Blob) == []
    assert rows(Attachment) == []
  end

  describe "attach" do
    test "a valid path function still attaches" do
      assert {:ok, %{blob: blob}} = Operations.attach(post!(), :valid, "data", filename: "x")
      assert "covers/" <> _ = blob.key
      assert AshStorage.Service.Test.list_keys() == [blob.key]
    end

    test "a key with a `..` segment fails the attach before anything is stored" do
      assert {:error, %Ash.Error.Unknown{} = error} =
               Operations.attach(post!(), :parent, "data", filename: "x")

      assert Exception.message(error) =~ "{:invalid_storage_key, :parent_segment, \"../../etc/"
      assert_nothing_stored()
    end

    test "an absolute key fails the attach" do
      assert {:error, error} = Operations.attach(post!(), :absolute, "data", filename: "x")

      assert Exception.message(error) =~
               ~s({:invalid_storage_key, :absolute, "/etc/passwd"})

      assert_nothing_stored()
    end

    test "an empty key fails the attach" do
      assert {:error, error} = Operations.attach(post!(), :empty, "data", filename: "x")
      assert Exception.message(error) =~ ~s({:invalid_storage_key, :empty, ""})
      assert_nothing_stored()
    end

    test "a path function that returns no string fails the attach" do
      assert {:error, error} = Operations.attach(post!(), :not_a_string, "data", filename: "x")
      assert Exception.message(error) =~ "{:invalid_storage_key, :not_a_binary, nil}"
      assert_nothing_stored()
    end

    test "a key with a character outside the allowed set fails the attach" do
      assert {:error, error} = Operations.attach(post!(), :spaced, "data", filename: "x")

      assert Exception.message(error) =~
               ~s({:invalid_storage_key, :invalid_character, "my photos/)

      assert_nothing_stored()
    end

    test "a tenant with a character outside the allowed set is rejected" do
      assert {:error, error} =
               Operations.attach(post!(), :plain, "data", filename: "x", tenant: "org:123")

      assert Exception.message(error) =~
               ~s({:invalid_storage_key, {:tenant, :invalid_character}, "org:123"})

      assert_nothing_stored()
    end

    test "a tenant that contains a slash is rejected, not turned into two segments" do
      assert {:error, error} =
               Operations.attach(post!(), :plain, "data", filename: "x", tenant: "acme/eu")

      assert Exception.message(error) =~
               ~s({:invalid_storage_key, {:tenant, :separator}, "acme/eu"})

      assert_nothing_stored()
    end

    test "a tenant of `..` is rejected" do
      assert {:error, error} =
               Operations.attach(post!(), :plain, "data", filename: "x", tenant: "..")

      assert Exception.message(error) =~
               ~s({:invalid_storage_key, {:tenant, :parent_segment}, ".."})

      assert_nothing_stored()
    end
  end

  describe "file arguments" do
    test "an invalid key fails the action, and neither the record nor the file is created" do
      path =
        Path.join(
          System.tmp_dir!(),
          "ash_storage_key_validation_#{System.unique_integer([:positive])}"
        )

      File.write!(path, "data")
      on_exit(fn -> File.rm(path) end)

      assert {:error, error} =
               Post
               |> Ash.Changeset.for_create(:create_with_file, %{
                 title: "post",
                 file: Ash.Type.File.from_path(path)
               })
               |> Ash.create()

      assert Exception.message(error) =~ "{:invalid_storage_key, :parent_segment,"
      assert rows(Post) == []
      assert_nothing_stored()
    end
  end

  describe "direct uploads" do
    test "an invalid key is refused before the blob is created" do
      assert {:error, {:invalid_storage_key, :parent_segment, "../../etc/" <> _}} =
               Operations.prepare_direct_upload(Post, :parent, filename: "photo.jpg")

      assert {:error, {:invalid_storage_key, :absolute, "/etc/passwd"}} =
               Operations.prepare_direct_upload(Post, :absolute, filename: "photo.jpg")

      assert {:error, {:invalid_storage_key, :invalid_character, "my photos/" <> _}} =
               Operations.prepare_direct_upload(Post, :spaced, filename: "photo.jpg")

      assert_nothing_stored()
    end

    test "a tenant that contains a slash is refused" do
      assert {:error, {:invalid_storage_key, {:tenant, :separator}, "acme/eu"}} =
               Operations.prepare_direct_upload(Post, :plain,
                 filename: "photo.jpg",
                 tenant: "acme/eu"
               )

      assert {:error, {:invalid_storage_key, {:tenant, :invalid_character}, "org:123"}} =
               Operations.prepare_direct_upload(Post, :plain,
                 filename: "photo.jpg",
                 tenant: "org:123"
               )

      assert_nothing_stored()
    end
  end

  describe "variants" do
    test "a variant of a blob whose key breaks the rules is not generated" do
      key = "org:123/#{AshStorage.generate_key()}"
      AshStorage.Service.Test.upload(key, "hello", AshStorage.Service.Context.new([]))

      blob =
        Ash.create!(
          Blob,
          %{
            key: key,
            filename: "hello.txt",
            content_type: "text/plain",
            byte_size: 5,
            checksum: Base.encode64(:crypto.hash(:md5, "hello")),
            service_name: AshStorage.Service.Test
          },
          action: :create
        )

      {:ok, attachment_def} = AshStorage.Info.attachment(Post, :document)
      [variant_def] = attachment_def.variants

      assert {:error, {:invalid_storage_key, :invalid_character, "org:123/" <> _}} =
               AshStorage.VariantGenerator.generate(blob, variant_def, Post, attachment_def)

      assert AshStorage.Service.Test.list_keys() == [key]
      assert [%{id: id}] = rows(Blob)
      assert id == blob.id
    end
  end
end
