defmodule AshStorage.AnalyzerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshStorage.Operations

  defmodule TooLargeAnalyzer do
    @moduledoc false
    @behaviour AshStorage.Analyzer

    @impl true
    def accept?(_), do: true

    @impl true
    def analyze(_path, _opts), do: {:error, "too large"}
  end

  defmodule LongReasonAnalyzer do
    @moduledoc false
    @behaviour AshStorage.Analyzer

    @impl true
    def accept?(_), do: true

    @impl true
    def analyze(_path, _opts), do: {:error, {:unreadable, String.duplicate("x", 600)}}
  end

  defmodule FailureDomain do
    @moduledoc false
    use Ash.Domain

    resources do
      resource AshStorage.AnalyzerTest.FailurePost
    end
  end

  defmodule FailurePost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.AnalyzerTest.FailureDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)

      has_one_attached :too_large do
        analyzer(AshStorage.AnalyzerTest.TooLargeAnalyzer)
      end

      has_one_attached :long_reason do
        analyzer(AshStorage.AnalyzerTest.LongReasonAnalyzer)
      end
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read, create: []]
    end
  end

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  defp create_post!(title \\ "test") do
    AshStorage.Test.AnalyzablePost
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

      log =
        capture_log(fn ->
          {:ok, %{blob: blob}} =
            Operations.attach(post, :risky_file, "hello world",
              filename: "risky.txt",
              content_type: "text/plain"
            )

          send(self(), {:blob, blob})
        end)

      assert_received {:blob, blob}
      failing = blob.analyzers[to_string(AshStorage.Test.FailingAnalyzer)]
      assert failing["status"] == "error"
      assert failing["error"] == ":analysis_failed"
      assert log =~ "FailingAnalyzer"
      assert log =~ blob.id
      # TestAnalyzer should still run successfully after the failure
      assert blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)]["status"] == "complete"
      refute Map.has_key?(blob.analyzers[to_string(AshStorage.Test.TestAnalyzer)], "error")
      assert blob.metadata["line_count"] == 1
    end

    test "a later success clears the reason of an earlier failure" do
      post = create_post!()

      {:ok, %{blob: blob}} =
        Operations.attach(post, :document, "one\ntwo",
          filename: "a.txt",
          content_type: "text/plain"
        )

      key = to_string(AshStorage.Test.TestAnalyzer)

      blob =
        Ash.update!(
          blob,
          %{analyzers: %{key => %{"status" => "error", "error" => ":earlier", "opts" => %{}}}},
          action: :update_metadata
        )

      assert {:ok, blob} = Operations.run_analyzer(blob, AshStorage.Test.TestAnalyzer)
      assert blob.analyzers[key] == %{"status" => "complete", "opts" => %{}}
    end

    test "keeps a reason given as text as it is" do
      post = Ash.create!(FailurePost, %{})

      {:ok, %{blob: blob}} =
        Operations.attach(post, :too_large, "data", filename: "big.bin")

      assert blob.analyzers[to_string(TooLargeAnalyzer)]["error"] == "too large"
    end

    test "cuts a long reason to 500 characters" do
      post = Ash.create!(FailurePost, %{})

      {:ok, %{blob: blob}} =
        Operations.attach(post, :long_reason, "data", filename: "odd.bin")

      error = blob.analyzers[to_string(LongReasonAnalyzer)]["error"]
      assert String.length(error) == 500
      assert String.starts_with?(error, "{:unreadable, ")
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

    test "works with a %Plug.Upload{} input" do
      post = create_post!()
      path = Path.join(System.tmp_dir!(), "ash_storage_analyzer_upload_test.txt")
      File.write!(path, "line one\nline two\n")

      upload = %Plug.Upload{path: path, filename: "test.txt", content_type: "text/plain"}

      assert {:ok, %{blob: blob}} =
               Operations.attach(post, :document, upload,
                 filename: "test.txt",
                 content_type: "text/plain"
               )

      assert blob.metadata["line_count"] == 3
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_analyzer_upload_test.txt"))
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
  end

  describe "write_attributes" do
    test "a file argument on a create records the new record as the write target" do
      path = Path.join(System.tmp_dir!(), "ash_storage_write_target_test.txt")
      File.write!(path, "one\ntwo")
      upload = %Plug.Upload{path: path, filename: "doc.txt", content_type: "text/plain"}

      post =
        Ash.create!(AshStorage.Test.MatrixPost, %{slug: "write-target", doc: upload},
          action: :create_with_doc
        )

      entry = post.__metadata__[:doc_blob].analyzers[to_string(AshStorage.Test.TestAnalyzer)]

      assert entry["write_target"]["id"] == post.id
      assert post.lines == 2
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_write_target_test.txt"))
    end

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
