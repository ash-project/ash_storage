defmodule AshStorage.Analyzer do
  @moduledoc """
  Behaviour for file analyzers that extract metadata from files.

  Analyzers examine file content and extract metadata such as image dimensions,
  video duration, audio sample rates, etc. Different analyzers handle different
  content types.

  ## Implementing an Analyzer

      defmodule MyApp.Storage.PdfAnalyzer do
        @behaviour AshStorage.Analyzer

        @impl true
        def accept?(content_type), do: content_type == "application/pdf"

        @impl true
        def analyze(path, _opts) do
          # Extract PDF metadata
          {:ok, %{page_count: 42}}
        end
      end
  """

  @doc """
  Returns true if this analyzer can handle the given content type.
  """
  @callback accept?(content_type :: String.t()) :: boolean()

  @doc """
  Analyze a file and return extracted metadata.

  The file is available at the given path for analysis. Returns a map
  of metadata keys and values that will be merged into the blob's metadata.
  """
  @callback analyze(path :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
