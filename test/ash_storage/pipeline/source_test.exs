defmodule AshStorage.Pipeline.SourceTest do
  use ExUnit.Case, async: true

  alias AshStorage.Pipeline.Source

  @content "hello\nworld\n"
  @md5 Base.encode64(:crypto.hash(:md5, @content))

  setup do
    path =
      Path.join(System.tmp_dir!(), "ash_storage_source_#{System.unique_integer([:positive])}")

    File.write!(path, @content)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp upload(path), do: %Plug.Upload{path: path, filename: "up.txt", content_type: "text/plain"}

  describe "new/2 reads the input once" do
    test "a binary, with no path" do
      assert %Source{data: @content, byte_size: 12, checksum: @md5, path: nil} =
               Source.new(@content)
    end

    test "iodata, with no path" do
      assert %Source{data: @content, checksum: @md5, path: nil} =
               Source.new(["hello", ?\n, ["world", "\n"]])
    end

    test "a File.Stream", %{path: path} do
      assert %Source{data: @content, checksum: @md5, path: ^path} =
               Source.new(File.stream!(path, [], 4))
    end

    test "an Ash.Type.File from a path", %{path: path} do
      assert %Source{data: @content, checksum: @md5, path: ^path} =
               Source.new(Ash.Type.File.from_path(path))
    end

    test "an Ash.Type.File from a Plug.Upload", %{path: path} do
      {:ok, file} = Ash.Type.cast_input(Ash.Type.File, upload(path))

      assert %Source{data: @content, checksum: @md5, path: ^path} = Source.new(file)
    end

    test "a raw Plug.Upload reads the file, not its path", %{path: path} do
      assert %Source{data: @content, byte_size: 12, checksum: @md5, path: ^path} =
               Source.new(upload(path))
    end
  end

  describe "filename and content type" do
    test "explicit options win", %{path: path} do
      {:ok, file} = Ash.Type.cast_input(Ash.Type.File, upload(path))
      source = Source.new(file, filename: "given.bin", content_type: "application/pdf")

      assert {source.filename, source.content_type} == {"given.bin", "application/pdf"}
    end

    test "come from an Ash.Type.File", %{path: path} do
      {:ok, file} = Ash.Type.cast_input(Ash.Type.File, upload(path))
      source = Source.new(file, metadata: %{"a" => 1})

      assert {source.filename, source.content_type} == {"up.txt", "text/plain"}
      assert source.metadata == %{"a" => 1}
    end

    test "default to upload and application/octet-stream" do
      source = Source.new("bytes")

      assert {source.filename, source.content_type} == {"upload", "application/octet-stream"}
      assert source.metadata == %{}
    end
  end

  describe "with_local_path/2" do
    test "a binary source gets a temporary file, removed afterwards" do
      source = Source.new(@content)

      path =
        Source.with_local_path(source, fn path ->
          assert File.read!(path) == @content
          path
        end)

      refute File.exists?(path)
    end

    test "the temporary file is removed when the function raises" do
      source = Source.new(@content)

      assert_raise RuntimeError, fn ->
        Source.with_local_path(source, fn path ->
          send(self(), {:path, path})
          raise "boom"
        end)
      end

      assert_received {:path, path}
      refute File.exists?(path)
    end

    test "an input with a path uses it and leaves it", %{path: path} do
      assert Source.with_local_path(Source.new(Ash.Type.File.from_path(path)), & &1) == path
      assert File.exists?(path)
    end
  end
end
