defmodule AshStorage.Test.TestAnalyzer do
  @moduledoc false
  @behaviour AshStorage.Analyzer

  @impl true
  def accept?("text/plain"), do: true
  def accept?(_), do: false

  @impl true
  def analyze(path, opts) do
    content = File.read!(path)
    result = %{"line_count" => length(String.split(content, "\n"))}

    result =
      if opts[:include_word_count] do
        Map.put(result, "word_count", length(String.split(content)))
      else
        result
      end

    {:ok, result}
  end
end

defmodule AshStorage.Test.ImageAnalyzer do
  @moduledoc false
  @behaviour AshStorage.Analyzer

  @impl true
  def accept?("image/" <> _), do: true
  def accept?(_), do: false

  @impl true
  def analyze(_path, _opts) do
    {:ok, %{"width" => 640, "height" => 480}}
  end
end

defmodule AshStorage.Test.FailingAnalyzer do
  @moduledoc false
  @behaviour AshStorage.Analyzer

  @impl true
  def accept?(_), do: true

  @impl true
  def analyze(_path, _opts) do
    {:error, :analysis_failed}
  end
end

defmodule AshStorage.Test.AnalyzablePost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  ets do
    private? true
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.Blob)
    attachment_resource(AshStorage.Test.Attachment)

    has_one_attached :document do
      analyzer AshStorage.Test.TestAnalyzer
    end

    has_one_attached :photo do
      analyzer {AshStorage.Test.TestAnalyzer, include_word_count: true}
      analyzer AshStorage.Test.ImageAnalyzer
    end

    has_one_attached :risky_file do
      analyzer AshStorage.Test.FailingAnalyzer
      analyzer AshStorage.Test.TestAnalyzer
    end

    has_one_attached :analyzed_doc do
      analyzer AshStorage.Test.TestAnalyzer, write_attributes: [line_count: :cached_line_count]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
    attribute :cached_line_count, :integer, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: []]

    create :create_with_doc do
      accept [:title]
      argument :document_file, Ash.Type.File, allow_nil?: true

      change {AshStorage.Changes.HandleFileArgument,
              argument: :document_file, attachment: :document}
    end
  end
end
