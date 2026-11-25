defmodule AshStorage.Pipeline.Source do
  @moduledoc false
  # The caller's input to an upload. Accepted shapes:
  #
  #   * `%Ash.Type.File{}` - opened and read in binary mode.
  #   * `%File.Stream{}`   - collected into a single binary.
  #   * `%Plug.Upload{}`   - read from its path. Matched by its `__struct__`
  #     so that `:plug` is not needed at compile time; without the clause its
  #     `:path` string would be taken for the bytes.
  #   * binary             - the bytes themselves, not a path.
  #   * iodata             - flattened into a binary.

  defstruct [:data, :byte_size, :checksum, :filename, :content_type, :path, metadata: %{}]

  @type t :: %__MODULE__{
          data: binary(),
          byte_size: non_neg_integer(),
          checksum: String.t(),
          filename: String.t(),
          content_type: String.t(),
          metadata: map(),
          path: String.t() | nil
        }

  @default_filename "upload"
  @default_content_type "application/octet-stream"

  @doc """
  Reads `io`. `:filename`, `:content_type` and `:metadata` come from `opts`;
  for an `Ash.Type.File` a missing filename or content type comes from the
  file.
  """
  @spec new(term(), keyword()) :: t()
  # sobelow_skip ["Crypto.WeakHash"]
  def new(io, opts \\ []) do
    data = read(io)
    {filename, content_type} = name_and_type(io)

    %__MODULE__{
      data: data,
      byte_size: byte_size(data),
      checksum: :crypto.hash(:md5, data) |> Base.encode64(),
      filename: opts[:filename] || filename,
      content_type: opts[:content_type] || content_type,
      metadata: opts[:metadata] || %{},
      path: path(io)
    }
  end

  @doc """
  The filename and content type an `Ash.Type.File` declares, with
  `"upload"` and `"application/octet-stream"` for what it does not declare
  and for any other input.
  """
  @spec name_and_type(term()) :: {String.t(), String.t()}
  def name_and_type(%Ash.Type.File{} = file) do
    {file_value(file, :filename, @default_filename),
     file_value(file, :content_type, @default_content_type)}
  end

  def name_and_type(_io), do: {@default_filename, @default_content_type}

  @doc """
  Calls `fun` with a local path holding the source's bytes: the input's own
  file when it has one, otherwise a temporary file removed afterwards.
  """
  @spec with_local_path(t(), (String.t() -> result)) :: result when result: term()
  def with_local_path(%__MODULE__{path: path}, fun) when is_binary(path), do: fun.(path)

  # sobelow_skip ["Traversal.FileModule"]
  def with_local_path(%__MODULE__{data: data}, fun) do
    path = Path.join(System.tmp_dir!(), "ash_storage_analyze_#{AshStorage.generate_key()}")
    File.write!(path, data)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp read(%Ash.Type.File{} = file) do
    {:ok, device} = Ash.Type.File.open(file, [:read, :binary])
    data = IO.binread(device, :eof)
    File.close(device)
    data
  end

  defp read(%File.Stream{} = stream), do: Enum.into(stream, <<>>, &IO.iodata_to_binary/1)

  # sobelow_skip ["Traversal.FileModule"]
  defp read(%{__struct__: Plug.Upload, path: path}) when is_binary(path), do: File.read!(path)

  defp read(data) when is_binary(data), do: data
  defp read(data) when is_list(data), do: IO.iodata_to_binary(data)

  defp path(%Ash.Type.File{} = file) do
    case Ash.Type.File.path(file) do
      {:ok, path} -> path
      _ -> nil
    end
  end

  defp path(%File.Stream{path: path}), do: path
  defp path(%{__struct__: Plug.Upload, path: path}) when is_binary(path), do: path
  defp path(_io), do: nil

  # `Ash.Type.File.filename/1` and `content_type/1` are missing from older Ash
  # versions
  defp file_value(file, function, default) do
    with true <- function_exported?(Ash.Type.File, function, 1),
         {:ok, value} when is_binary(value) <- apply(Ash.Type.File, function, [file]) do
      value
    else
      _ -> default
    end
  end
end
