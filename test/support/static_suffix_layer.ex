defmodule AshStorage.Test.StaticSuffixLayer do
  @moduledoc false
  @behaviour AshStorage.Layer

  alias AshStorage.Layer

  @impl true
  def default_metadata_key(opts), do: "static-suffix-#{Keyword.fetch!(opts, :suffix)}"

  @impl true
  def write(write, opts) do
    suffix = Keyword.fetch!(opts, :suffix)

    {:ok,
     write
     |> Layer.put_metadata(Layer.layer_metadata_key({__MODULE__, opts}), %{"suffix" => suffix})
     |> Map.put(:data, write.data <> suffix)}
  end

  @impl true
  def read(read, opts) do
    suffix = Keyword.fetch!(opts, :suffix)

    {:ok, %{read | data: String.replace_suffix(read.data, suffix, "")}}
  end
end
