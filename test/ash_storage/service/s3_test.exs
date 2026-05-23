defmodule AshStorage.Service.S3Test do
  use ExUnit.Case, async: true

  alias AshStorage.Service.Context
  alias AshStorage.Service.S3

  @bucket "ash-storage-unit"

  defp ctx(extra_opts, stub_name) do
    Context.new(
      [
        bucket: @bucket,
        region: "us-east-1",
        access_key_id: "AKIAFAKE",
        secret_access_key: "secret",
        plug: {Req.Test, stub_name}
      ] ++ extra_opts
    )
  end

  describe "upload/3 Content-Type" do
    test "sets Content-Type header from ctx.content_type" do
      stub = :"#{__MODULE__}.CtFromCtx"
      Req.Test.stub(stub, &capture_and_respond/1)

      ctx = ctx([], stub) |> Context.put_content_type("image/svg+xml")
      :ok = S3.upload("photo.svg", "<svg/>", ctx)

      assert {"PUT", _path, headers, _body} = take_request()
      assert get_header(headers, "content-type") == "image/svg+xml"
    end

    test "ctx.content_type takes precedence over service_opts[:content_type]" do
      stub = :"#{__MODULE__}.Precedence"
      Req.Test.stub(stub, &capture_and_respond/1)

      ctx =
        ctx([content_type: "image/jpeg"], stub)
        |> Context.put_content_type("image/png")

      :ok = S3.upload("photo.png", "data", ctx)
      {_, _, headers, _} = take_request()
      assert get_header(headers, "content-type") == "image/png"
    end

    test "falls back to service_opts[:content_type] when ctx.content_type is nil" do
      stub = :"#{__MODULE__}.ServiceOptsFallback"
      Req.Test.stub(stub, &capture_and_respond/1)

      :ok = S3.upload("photo.jpg", "data", ctx([content_type: "image/jpeg"], stub))
      {_, _, headers, _} = take_request()
      assert get_header(headers, "content-type") == "image/jpeg"
    end

    test "falls back to application/octet-stream when both are nil" do
      stub = :"#{__MODULE__}.DefaultFallback"
      Req.Test.stub(stub, &capture_and_respond/1)

      :ok = S3.upload("blob.bin", "data", ctx([], stub))
      {_, _, headers, _} = take_request()
      assert get_header(headers, "content-type") == "application/octet-stream"
    end
  end

  describe "upload/3 Content-MD5 + Content-Type interaction" do
    test "Content-MD5 and Content-Type coexist on the same PUT" do
      stub = :"#{__MODULE__}.Md5AndCt"
      Req.Test.stub(stub, &capture_and_respond/1)

      data = "checksum-and-type"
      md5 = Base.encode64(:crypto.hash(:md5, data))

      ctx =
        ctx([], stub)
        |> Context.put_expected_md5(md5)
        |> Context.put_content_type("text/plain")

      :ok = S3.upload("doc.txt", data, ctx)

      {_, _, headers, _} = take_request()
      assert get_header(headers, "content-type") == "text/plain"
      assert get_header(headers, "content-md5") == md5
    end
  end

  describe "download_with_metadata/2" do
    test "returns upstream Content-Type" do
      stub = :"#{__MODULE__}.DownloadMetadata"

      Req.Test.stub(stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/svg+xml")
        |> Plug.Conn.send_resp(200, "<svg/>")
      end)

      ctx = ctx([], stub)

      assert {:ok, %{body: "<svg/>", content_type: "image/svg+xml" <> _}} =
               S3.download_with_metadata("photo.svg", ctx)
    end
  end

  # -- Helpers --

  defp capture_and_respond(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    Process.put(
      :s3_test_last_request,
      {conn.method, conn.request_path, conn.req_headers, body}
    )

    Plug.Conn.send_resp(conn, 200, "")
  end

  defp take_request, do: Process.get(:s3_test_last_request)

  defp get_header(headers, name) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _ -> nil
    end)
  end
end
