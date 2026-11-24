defmodule AshStorage.FileArgumentTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule Notifier do
    @moduledoc false
    use Ash.Notifier

    @impl true
    def notify(%Ash.Notifier.Notification{action: action}) do
      send(self(), {:notified, action.name})
      :ok
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule NestedAttachPost do
    @moduledoc false
    # Attaches the file argument by running the generated `attach_cover_image`
    # action from an `after_action` hook, as the "Migrating to 1.0" guide shows
    use Ash.Resource,
      domain: AshStorage.FileArgumentTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage],
      simple_notifiers: [AshStorage.FileArgumentTest.Notifier]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)

      has_one_attached :cover_image do
        analyzer(AshStorage.Test.TestAnalyzer, write_attributes: [line_count: :lines])
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
      attribute :lines, :integer, public?: true
      create_timestamp :inserted_at
      update_timestamp :updated_at
    end

    actions do
      defaults [:read]

      create :create do
        accept [:title]
        argument :cover_image, :file, allow_nil?: true

        change fn changeset, context ->
          Ash.Changeset.after_action(changeset, fn changeset, record ->
            case Ash.Changeset.get_argument(changeset, :cover_image) do
              nil ->
                {:ok, record}

              file ->
                filename =
                  case Ash.Type.File.filename(file) do
                    {:ok, filename} -> filename
                    _ -> "upload"
                  end

                content_type =
                  case Ash.Type.File.content_type(file) do
                    {:ok, content_type} -> content_type
                    _ -> "application/octet-stream"
                  end

                opts =
                  Ash.Context.to_opts(context, filename: filename, content_type: content_type)

                with {:ok, %{record: record}} <-
                       AshStorage.Operations.attach(record, :cover_image, file, opts) do
                  {:ok, record}
                end
            end
          end)
        end
      end
    end
  end

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
      assert post.cover_image.blob.filename

      assert {:ok, "hello from create"} =
               AshStorage.Service.Test.download(post.cover_image.blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_create_test.txt"))
    end

    test "puts the blob and the attachment on the result" do
      path = Path.join(System.tmp_dir!(), "ash_storage_create_metadata_test.txt")
      File.write!(path, "metadata")

      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{
          title: "with metadata",
          cover_image: Ash.Type.File.from_path(path)
        })
        |> Ash.create!()

      assert %{id: blob_id} = post.__metadata__[:cover_image_blob]
      assert post.__metadata__[:cover_image_attachment].blob_id == blob_id
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_create_metadata_test.txt"))
    end

    test "skips attach when argument is nil" do
      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create_with_image, %{title: "no image"})
        |> Ash.create!()

      post = Ash.load!(post, :cover_image)
      assert post.cover_image == nil
    end

    test "the actor reaches the service" do
      path = Path.join(System.tmp_dir!(), "ash_storage_actor_opts_test.txt")
      File.write!(path, "actor opts")

      post =
        AshStorage.Test.ActorRequiredPost
        |> Ash.Changeset.for_create(
          :create_with_image,
          %{
            title: "with actor",
            cover_image: Ash.Type.File.from_path(path)
          },
          actor: :authorized
        )
        |> Ash.create!()

      post = Ash.load!(post, cover_image: :blob)

      assert {:ok, "actor opts"} = AshStorage.Service.Test.download(post.cover_image.blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_actor_opts_test.txt"))
    end

    test "the actor reaches the service during bulk create" do
      path1 = Path.join(System.tmp_dir!(), "ash_storage_bulk_actor_opts_1.txt")
      path2 = Path.join(System.tmp_dir!(), "ash_storage_bulk_actor_opts_2.txt")

      File.write!(path1, "bulk actor opts 1")
      File.write!(path2, "bulk actor opts 2")

      result =
        Ash.bulk_create(
          [
            %{title: "bulk 1", cover_image: Ash.Type.File.from_path(path1)},
            %{title: "bulk 2", cover_image: Ash.Type.File.from_path(path2)}
          ],
          AshStorage.Test.ActorRequiredPost,
          :create_with_image,
          actor: :authorized,
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert [post1, post2] = Ash.load!(result.records, cover_image: :blob)

      assert {:ok, "bulk actor opts 1"} =
               AshStorage.Service.Test.download(post1.cover_image.blob.key, [])

      assert {:ok, "bulk actor opts 2"} =
               AshStorage.Service.Test.download(post2.cover_image.blob.key, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_bulk_actor_opts_1.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_bulk_actor_opts_2.txt"))
    end
  end

  describe "bulk create with :file argument" do
    test "attaches per record and keeps records without a file in place" do
      path1 = Path.join(System.tmp_dir!(), "ash_storage_bulk_mixed_1.txt")
      path3 = Path.join(System.tmp_dir!(), "ash_storage_bulk_mixed_3.txt")
      File.write!(path1, "first")
      File.write!(path3, "third")

      result =
        Ash.bulk_create(
          [
            %{title: "one", cover_image: Ash.Type.File.from_path(path1)},
            %{title: "two"},
            %{title: "three", cover_image: Ash.Type.File.from_path(path3)}
          ],
          AshStorage.Test.Post,
          :create_with_image,
          return_records?: true,
          return_errors?: true,
          sorted?: true
        )

      assert result.status == :success
      assert [one, two, three] = Ash.load!(result.records, cover_image: :blob)
      assert Enum.map([one, two, three], & &1.title) == ["one", "two", "three"]

      assert {:ok, "first"} = AshStorage.Service.Test.download(one.cover_image.blob.key, [])
      assert two.cover_image == nil
      assert {:ok, "third"} = AshStorage.Service.Test.download(three.cover_image.blob.key, [])
      assert length(AshStorage.Service.Test.list_keys()) == 2
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_bulk_mixed_1.txt"))
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_bulk_mixed_3.txt"))
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
      assert post.cover_image.blob.filename
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
      assert post.cover_image.blob.filename

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

  describe "attaching through the generated action from an after_action hook" do
    test "runs that action and returns its record" do
      path = Path.join(System.tmp_dir!(), "ash_storage_nested_attach.txt")
      File.write!(path, "one\ntwo")
      upload = %Plug.Upload{path: path, filename: "nested.txt", content_type: "text/plain"}

      log =
        capture_log(fn ->
          post =
            Ash.create!(NestedAttachPost, %{title: "nested", cover_image: upload},
              action: :create
            )

          send(self(), {:post, post})
        end)

      assert_received {:post, post}
      assert log == ""
      assert Ash.load!(post, cover_image: :blob).cover_image.blob.filename == "nested.txt"
      assert_received {:notified, :attach_cover_image}
      assert DateTime.compare(post.updated_at, post.inserted_at) == :gt
      assert post.lines == 2
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_nested_attach.txt"))
    end
  end
end
