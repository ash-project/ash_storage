defmodule AshStorage.AnalyzerTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test") do
    AshStorage.Test.AnalyzablePost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  defp create_layered_post!(title \\ "layered") do
    AshStorage.Test.LayeredPost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end

  describe "eager analyzers" do
    test "runs analyzer and merges metadata into blob" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :document, "hello\nworld\n",
          filename: "hello.txt",
          content_type: "text/plain"
        )

      assert blob.metadata["line_count"] == 3
      assert blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] == "complete"
    end

    test "passes opts to analyzer" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :photo, "hello world",
          filename: "photo.txt",
          content_type: "text/plain"
        )

      # TestAnalyzer with include_word_count: true
      assert blob.metadata["word_count"] == 2
      assert blob.metadata["line_count"] == 1
    end

    test "skips analyzers that don't accept the content type" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :photo, "hello",
          filename: "photo.txt",
          content_type: "text/plain"
        )

      # ImageAnalyzer doesn't accept text/plain
      refute Map.has_key?(blob.metadata, "width")
      # But it's still tracked as pending in the analyzers map
      assert blob.analyzers[to_string(AshStorage.Test.ImageAnalyzer)]["status"] == "pending"
    end

    test "marks failed analyzers as error and continues" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :risky_file, "hello world",
          filename: "risky.txt",
          content_type: "text/plain"
        )

      assert blob.analyzers[to_string(AshStorage.Test.FailingAnalyzer)]["status"] == "error"
      # TestAnalyzer should still run successfully after the failure
      assert blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] == "complete"
      assert blob.metadata["line_count"] == 1
    end

    test "no analyzers configured means no analysis" do
      AshStorage.Service.Test.reset!()

      regular_post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create, %{title: "regular"})
        |> Ash.create!()

      {:ok, %{blob: blob}} =
        Operations.attach(regular_post, :cover_image, "data",
          filename: "f.txt",
          content_type: "text/plain"
        )

      assert blob.analyzers == %{}
      assert blob.metadata == %{}
    end

    test "works with Ash.Type.File input" do
      post = create_post!()
      path = Path.join(System.tmp_dir!(), "ash_storage_analyzer_test.txt")
      File.write!(path, "line one\nline two\n")

      file = Ash.Type.File.from_path(path)

      {:ok, %{blob: blob}} =
        Operations.attach(post, :document, file,
          filename: "test.txt",
          content_type: "text/plain"
        )

      assert blob.metadata["line_count"] == 3
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_analyzer_test.txt"))
    end

    test "preserves user-provided metadata alongside analyzer results" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :document, "hello",
          filename: "hello.txt",
          content_type: "text/plain",
          metadata: %{"custom" => "value"}
        )

      assert blob.metadata["custom"] == "value"
      assert blob.metadata["line_count"] == 1
    end

    test "stores analyzer opts in the analyzers map" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :photo, "data",
          filename: "photo.txt",
          content_type: "text/plain"
        )

      analyzer_entry = blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]
      assert analyzer_entry["opts"] == %{"include_word_count" => true}
    end

    test "stores analyzer source context in the analyzers map" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :photo, "data",
          filename: "photo.txt",
          content_type: "text/plain"
        )

      source = blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["source"]

      assert source == %{
               "resource" => to_string(AshStorage.Test.AnalyzablePost),
               "attachment" => "photo"
             }
    end

    test "stores analyzer source context for file argument attachments" do
      path = Path.join(System.tmp_dir!(), "ash_storage_analyzer_arg_test.txt")
      File.write!(path, "hello\n")

      file = Ash.Type.File.from_path(path)

      post =
        AshStorage.Test.AnalyzablePost
        |> Ash.Changeset.for_create(:create_with_doc, %{
          title: "with arg",
          document_file: file
        })
        |> Ash.create!()

      blob = post.__metadata__[:document_blob]
      source = blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["source"]

      assert source == %{
               "resource" => to_string(AshStorage.Test.AnalyzablePost),
               "attachment" => "document"
             }
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_analyzer_arg_test.txt"))
    end
  end

  describe "async analyzer BlobIO context" do
    test "uses analyzer source context to read layered blobs" do
      post = create_layered_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "hello\nworld\n",
          filename: "hello.txt",
          content_type: "text/plain"
        )

      assert {:ok, "hello\nworld\n-resource-cover"} =
               AshStorage.Service.Test.download(blob.key, [])

      {:ok, attachment_def} =
        AshStorage.Info.attachment(AshStorage.Test.LayeredPost, :cover_image)

      analyzer_key = to_string(AshStorage.Test.TestAnalyzer)

      {:ok, blob} =
        Ash.update(
          blob,
          %{
            analyzers: %{
              analyzer_key => %{
                "status" => "pending",
                "opts" => %{},
                "source" =>
                  AshStorage.AnalyzerMetadata.source(
                    AshStorage.Test.LayeredPost,
                    attachment_def
                  )
              }
            }
          },
          action: :update_metadata
        )

      {:ok, updated_blob} = Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)

      assert updated_blob.metadata["line_count"] == 3
      assert updated_blob.analyzers[analyzer_key]["status"] == "complete"
    end

    test "returns a context error for layered blobs with old analyzer metadata" do
      post = create_layered_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :cover_image, "hello",
          filename: "hello.txt",
          content_type: "text/plain"
        )

      analyzer_key = to_string(AshStorage.Test.TestAnalyzer)

      {:ok, blob} =
        Ash.update(
          blob,
          %{
            analyzers: %{
              analyzer_key => %{"status" => "pending", "opts" => %{}}
            }
          },
          action: :update_metadata
        )

      assert {:error, {:missing_blob_io_context, :analyzer, ^analyzer_key}} =
               Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)
    end
  end

  describe "write_attributes" do
    test "writes analyzer results to parent record attributes" do
      post = create_post!()

      {:ok, %{record: updated_post}} =
        Operations.attach(post, :analyzed_doc, "hello\nworld\n",
          filename: "hello.txt",
          content_type: "text/plain"
        )

      assert updated_post.cached_line_count == 3
    end

    test "does not write when analyzer fails" do
      post = create_post!()

      # Use a content type that TestAnalyzer doesn't accept to trigger "pending" status
      {:ok, %{record: updated_post}} =
        Operations.attach(post, :analyzed_doc, "binary data",
          filename: "photo.png",
          content_type: "image/png"
        )

      assert updated_post.cached_line_count == nil
    end
  end
end
