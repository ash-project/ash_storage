defmodule AshStorage.Transformer do
  @moduledoc """
  Behaviour for file transformers that create variants of files.

  Transformers apply transformations to files (typically images) to create
  variants such as thumbnails, resized versions, etc.

  ## Implementing a Transformer

      defmodule MyApp.Storage.ThumbnailTransformer do
        @behaviour AshStorage.Transformer

        @impl true
        def transform(source_path, dest_path, opts) do
          # Apply transformation
          :ok
        end
      end
  """

  @doc """
  Transform a file from source_path and write the result to dest_path.

  ## Options

  Options are transformer-specific and define the transformation to apply.
  """
  @callback transform(
              source_path :: String.t(),
              dest_path :: String.t(),
              opts :: keyword()
            ) :: :ok | {:error, term()}
end
