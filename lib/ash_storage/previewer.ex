defmodule AshStorage.Previewer do
  @moduledoc """
  Behaviour for generating preview images from non-image files.

  Previewers generate preview images for files like PDFs, videos, documents, etc.

  ## Implementing a Previewer

      defmodule MyApp.Storage.VideoPreviewer do
        @behaviour AshStorage.Previewer

        @impl true
        def accept?(content_type), do: String.starts_with?(content_type, "video/")

        @impl true
        def preview(source_path, dest_path, _opts) do
          # Generate video thumbnail
          :ok
        end
      end
  """

  @doc """
  Returns true if this previewer can handle the given content type.
  """
  @callback accept?(content_type :: String.t()) :: boolean()

  @doc """
  Generate a preview image from the source file.

  Reads the file at source_path and writes a preview image to dest_path.
  """
  @callback preview(
              source_path :: String.t(),
              dest_path :: String.t(),
              opts :: keyword()
            ) :: :ok | {:error, term()}
end
