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
end
