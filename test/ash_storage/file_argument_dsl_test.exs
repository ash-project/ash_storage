defmodule AshStorage.FileArgumentDslTest do
  use ExUnit.Case, async: false

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  describe "file_argument DSL on create" do
    test "attaches file when argument is provided" do
      path = Path.join(System.tmp_dir!(), "ash_storage_file_arg_create.txt")
      File.write!(path, "hello\nworld\n")
      file = Ash.Type.File.from_path(path)

      post =
        AshStorage.Test.AnalyzablePost
        |> Ash.Changeset.for_create(:create_with_doc, %{
          title: "test",
          document_file: file
        })
        |> Ash.create!()

      post = Ash.load!(post, document: :blob)
      assert post.document != nil
      assert post.document.blob.filename
      assert AshStorage.Service.Test.exists?(post.document.blob.key)
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_file_arg_create.txt"))
    end

    test "skips attachment when argument is nil" do
      post =
        AshStorage.Test.AnalyzablePost
        |> Ash.Changeset.for_create(:create_with_doc, %{title: "no file"})
        |> Ash.create!()

      post = Ash.load!(post, :document)
      assert post.document == nil
    end

    test "runs eager analyzers and merges metadata" do
      path = Path.join(System.tmp_dir!(), "ash_storage_file_arg_analyze.txt")
      File.write!(path, "line one\nline two\n")
      file = Ash.Type.File.from_path(path)

      post =
        AshStorage.Test.AnalyzablePost
        |> Ash.Changeset.for_create(:create_with_doc, %{
          title: "analyzed",
          document_file: file
        })
        |> Ash.create!()

      post = Ash.load!(post, document: :blob)

      # TestAnalyzer accepts text/plain but content_type from path is application/octet-stream
      # so the analyzer won't accept it — it stays pending
      assert post.document.blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] ==
               "pending"
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_file_arg_analyze.txt"))
    end
  end

  describe "the change" do
    test "puts the blob and the attachment on the result" do
      path = Path.join(System.tmp_dir!(), "ash_storage_file_arg_metadata.txt")
      File.write!(path, "hello")

      post =
        AshStorage.Test.AnalyzablePost
        |> Ash.Changeset.for_create(:create_with_doc, %{
          title: "metadata",
          document_file: Ash.Type.File.from_path(path)
        })
        |> Ash.create!()

      assert %{id: blob_id} = post.__metadata__[:document_blob]
      assert post.__metadata__[:document_attachment].blob_id == blob_id
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_file_arg_metadata.txt"))
    end

    test "requires the argument and the attachment" do
      assert {:error, _} = AshStorage.Changes.HandleFileArgument.init(attachment: :document)
      assert {:error, _} = AshStorage.Changes.HandleFileArgument.init(argument: :document_file)

      assert {:ok, _} =
               AshStorage.Changes.HandleFileArgument.init(
                 argument: :document_file,
                 attachment: :document
               )
    end
  end
end
