defmodule AshStorage.BlobIOTest do
  use ExUnit.Case, async: false

  alias AshStorage.BlobIO
  alias AshStorage.Info
  alias AshStorage.Service
  alias AshStorage.Test.Post

  defmodule MetadataLayer do
    @behaviour AshStorage.Layer

    @impl true
    def default_metadata_key(_opts), do: "metadata-layer"

    @impl true
    def write(write, opts) do
      send(opts[:pid], {:layer, :write, write.data, write.blob_context.operation})

      {:ok,
       write
       |> AshStorage.Layer.put_metadata(default_metadata_key(opts), %{
         "format" => "wrapped-prefix"
       })
       |> Map.put(:data, "wrapped:#{write.data}")}
    end

    @impl true
    def read(read, opts) do
      send(opts[:pid], {:layer, :read, read.data, read.layer_metadata})

      if AshStorage.Layer.metadata(read, default_metadata_key(opts)) != [] do
        {:ok, %{read | data: String.replace_prefix(read.data, "wrapped:", "")}}
      else
        {:ok, read}
      end
    end
  end

  defmodule OrderedLayer do
    @behaviour AshStorage.Layer

    @impl true
    def default_metadata_key(opts), do: "ordered-#{opts[:name]}"

    @impl true
    def write(write, opts) do
      name = opts[:name]
      send(opts[:pid], {:layer, :write, name})

      {:ok,
       write
       |> AshStorage.Layer.put_metadata(default_metadata_key(opts), %{
         "suffix" => to_string(name)
       })
       |> Map.put(:data, write.data <> to_string(name))}
    end

    @impl true
    def read(read, opts) do
      name = opts[:name]
      send(opts[:pid], {:layer, :read, name})

      {:ok, %{read | data: String.replace_suffix(read.data, to_string(name), "")}}
    end
  end

  defmodule ServingLayer do
    @behaviour AshStorage.Layer

    @impl true
    def default_metadata_key(_opts), do: "serving-layer"

    @impl true
    def serving(serving, opts) do
      send(opts[:pid], {:layer, :serving, serving.key})

      {:ok,
       %{
         serving
         | call_opts:
             Keyword.merge(serving.call_opts,
               serve: :proxy,
               proxy_base_url: opts[:proxy_base_url]
             )
       }}
    end
  end

  defmodule DirectUploadLayer do
    @behaviour AshStorage.Layer

    @impl true
    def default_metadata_key(_opts), do: "direct-upload-layer"

    @impl true
    def direct_upload(direct_upload, opts) do
      send(opts[:pid], {:layer, :direct_upload, direct_upload.draft.filename})

      draft = %{
        direct_upload.draft
        | filename: "layered-#{direct_upload.draft.filename}"
      }

      {:ok,
       direct_upload
       |> AshStorage.Layer.put_metadata(default_metadata_key(opts), %{
         "policy" => "adjust-filename"
       })
       |> Map.put(:draft, draft)}
    end
  end

  defmodule FailingReadLayer do
    @behaviour AshStorage.Layer

    @impl true
    def default_metadata_key(_opts), do: "failing-read-layer"

    @impl true
    def read(_read, _opts), do: {:error, :read_layer_failed}
  end

  setup do
    Service.Test.reset!()
    :ok
  end

  defp layer_metadata(metadata) do
    get_in(metadata, ["ash_storage", "blob_io", "layers"])
  end

  test "context projects to service context" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        actor: :actor,
        tenant: "tenant",
        operation: :attach
      )

    service_ctx = BlobIO.BlobContext.to_service_context(bctx, table: :custom)

    assert %Service.Context{} = service_ctx
    assert service_ctx.service_opts == [table: :custom]
    assert service_ctx.resource == Post
    assert service_ctx.attachment == attachment
    assert service_ctx.actor == :actor
    assert service_ctx.tenant == "tenant"
  end

  test "write creates a blob and read returns stored bytes" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("hello world", bctx,
               filename: "hello.txt",
               content_type: "text/plain",
               metadata: %{"source" => "test"}
             )

    assert blob.filename == "hello.txt"
    assert blob.content_type == "text/plain"
    assert blob.byte_size == 11
    assert blob.checksum == Base.encode64(:crypto.hash(:md5, "hello world"))
    assert blob.metadata == %{"source" => "test"}
    assert Service.Test.exists?(blob.key)

    read_bctx = BlobIO.BlobContext.new(blob: blob, operation: :download)

    assert {:ok, "hello world"} = BlobIO.read(blob, read_bctx)
  end

  test "layers can wrap stored bytes and use metadata to unwrap reads" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)
    layers = [{MetadataLayer, pid: self()}]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("logical", bctx,
               filename: "wrapped.txt",
               metadata: %{"source" => "test"},
               layers: layers
             )

    assert_receive {:layer, :write, "logical", :attach}

    assert blob.metadata["source"] == "test"

    assert layer_metadata(blob.metadata) == [
             %{
               "layer_metadata_key" => "metadata-layer",
               "metadata" => %{"format" => "wrapped-prefix"}
             }
           ]

    assert {:ok, "wrapped:logical"} =
             Service.Test.download(blob.key, Service.Context.new([]))

    read_bctx = BlobIO.BlobContext.new(blob: blob, operation: :download)

    assert {:ok, "logical"} = BlobIO.read(blob, read_bctx, layers: layers)

    assert_receive {:layer, :read, "wrapped:logical",
                    [
                      %{
                        "layer_metadata_key" => "metadata-layer",
                        "metadata" => %{"format" => "wrapped-prefix"}
                      }
                    ]}
  end

  test "read layers run in reverse order to unwind write layers" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {OrderedLayer, name: :a, pid: self()},
      {OrderedLayer, name: :b, pid: self()}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} = BlobIO.write("data", bctx, filename: "ordered.txt", layers: layers)

    assert_receive {:layer, :write, :a}
    assert_receive {:layer, :write, :b}

    assert {:ok, "dataab"} = Service.Test.download(blob.key, Service.Context.new([]))

    read_bctx = BlobIO.BlobContext.new(blob: blob, operation: :download)
    read_layers = Enum.reverse(layers)

    assert layer_metadata(blob.metadata) == [
             %{
               "layer_metadata_key" => "ordered-a",
               "metadata" => %{"suffix" => "a"}
             },
             %{
               "layer_metadata_key" => "ordered-b",
               "metadata" => %{"suffix" => "b"}
             }
           ]

    assert {:ok, "data"} = BlobIO.read(blob, read_bctx, layers: read_layers)

    assert_receive {:layer, :read, :b}
    assert_receive {:layer, :read, :a}
  end

  test "read returns an error when persisted layer metadata cannot be matched" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)
    layers = [{OrderedLayer, name: :missing, pid: self()}]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} = BlobIO.write("data", bctx, filename: "missing-layer.txt", layers: layers)
    assert_receive {:layer, :write, :missing}

    read_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :download
      )

    assert {:error, {:missing_blob_io_layer, "ordered-missing"}} =
             BlobIO.read(blob, read_bctx)
  end

  test "read returns layer callback errors unchanged" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} = BlobIO.write("data", bctx, filename: "failing-read-layer.txt")

    read_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :download
      )

    assert {:error, :read_layer_failed} =
             BlobIO.read(blob, read_bctx, layers: [FailingReadLayer])
  end

  test "serving_strategy returns the service URL strategy" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    assert {:service_url, "http://test.local/storage/" <> _} =
             BlobIO.serving_strategy(blob, serve_bctx)

    assert BlobIO.url(blob, serve_bctx) == "http://test.local/storage/#{blob.key}"
  end

  test "serving derives the service from the blob's persisted opts, not the runtime config" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    # Persist a blob whose stored service_opts pin a base_url that the runtime
    # DSL service config does not set.
    write_bctx =
      BlobIO.BlobContext.new(resource: Post, attachment: attachment, operation: :attach)

    {:ok, blob} =
      BlobIO.write("data", write_bctx,
        filename: "photo.jpg",
        service: {Service.Test, [base_url: "http://persisted.example/store"]}
      )

    blob = Ash.load!(blob, :parsed_service_opts)
    assert Keyword.get(blob.parsed_service_opts, :base_url) == "http://persisted.example/store"

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    # Serving must use the blob's persisted service_opts so it resolves the same
    # location as reading. Previously serving used the runtime service config
    # (no base_url) and diverged from the read path.
    assert BlobIO.url(blob, serve_bctx) == "http://persisted.example/store/#{blob.key}"
  end

  test "serving_strategy can return a proxy URL strategy" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    opts = [serve: :proxy, proxy_base_url: "/proxy/storage/"]
    expected_url = "/proxy/storage/#{blob.key}"

    assert {:proxy_url, ^expected_url} = BlobIO.serving_strategy(blob, serve_bctx, opts)

    assert BlobIO.url(blob, serve_bctx, opts) == expected_url
  end

  test "serving layers can select the proxy strategy" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    layers = [{ServingLayer, pid: self(), proxy_base_url: "/layered/proxy"}]

    assert BlobIO.url(blob, serve_bctx, layers: layers) == "/layered/proxy/#{blob.key}"

    assert_receive {:layer, :serving, key}
    assert key == blob.key
  end

  test "proxy URL strategy can sign proxy URLs" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    url =
      BlobIO.url(blob, serve_bctx,
        serve: :proxy,
        proxy_base_url: "/proxy/storage",
        proxy_secret: "proxy-secret",
        expires_in: 300,
        disposition: "attachment",
        filename: "photo.jpg"
      )

    assert %URI{path: "/proxy/storage/" <> key, query: query} = URI.parse(url)
    assert key == blob.key

    params = URI.decode_query(query)
    expires_at = String.to_integer(params["expires"])

    assert params["token"] == AshStorage.Token.sign("proxy-secret", blob.key, expires_at)
    assert params["disposition"] == "attachment"
    assert params["filename"] == "photo.jpg"
  end

  test "proxy URL strategy can sign proxy URLs from access declaration" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    {:ok, blob} = BlobIO.write("data", bctx, filename: "photo.jpg")

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    url =
      BlobIO.url(blob, serve_bctx,
        serve: :proxy,
        proxy_base_url: "/proxy/storage",
        access: {:signed, secret: "proxy-secret"},
        expires_in: 300
      )

    assert %URI{path: "/proxy/storage/" <> key, query: query} = URI.parse(url)
    assert key == blob.key

    params = URI.decode_query(query)
    expires_at = String.to_integer(params["expires"])

    assert params["token"] == AshStorage.Token.sign("proxy-secret", blob.key, expires_at)
  end

  test "prepare_direct_upload creates a pending blob and upload info" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :direct_upload
      )

    assert {:ok, result} =
             BlobIO.prepare_direct_upload(bctx,
               filename: "photo.jpg",
               content_type: "image/jpeg",
               byte_size: 123
             )

    assert result.blob.filename == "photo.jpg"
    assert result.blob.content_type == "image/jpeg"
    assert result.blob.byte_size == 123
    assert result.url == "http://test.local/storage/direct/#{result.blob.key}"
  end

  test "direct upload layers can adjust blob metadata before upload info is prepared" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :direct_upload
      )

    layers = [{DirectUploadLayer, pid: self()}]

    assert {:ok, result} =
             BlobIO.prepare_direct_upload(bctx,
               filename: "photo.jpg",
               content_type: "image/jpeg",
               layers: layers
             )

    assert result.blob.filename == "layered-photo.jpg"

    assert layer_metadata(result.blob.metadata) == [
             %{
               "layer_metadata_key" => "direct-upload-layer",
               "metadata" => %{"policy" => "adjust-filename"}
             }
           ]

    assert_receive {:layer, :direct_upload, "photo.jpg"}
  end
end
