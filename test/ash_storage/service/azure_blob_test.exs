defmodule AshStorage.Service.AzureBlobTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.AzureBlob
  alias AshStorage.Service.Context

  @account "myaccount"
  @container "uploads"
  @account_key Base.encode64("test account key")

  describe "url/2" do
    test "generates an unsigned public URL" do
      ctx = Context.new(account: @account, container: @container)

      assert AzureBlob.url("folder/my file.txt", ctx) ==
               "https://myaccount.blob.core.windows.net/uploads/folder/my%20file.txt"
    end

    test "applies prefixes before encoding URLs" do
      ctx = Context.new(account: @account, container: @container, prefix: "tenant one/")

      assert AzureBlob.url("folder/my file.txt", ctx) ==
               "https://myaccount.blob.core.windows.net/uploads/tenant%20one/folder/my%20file.txt"
    end

    test "uses custom endpoint URLs" do
      ctx =
        Context.new(
          account: "devstoreaccount1",
          container: @container,
          endpoint_url: "http://127.0.0.1:10000/devstoreaccount1"
        )

      assert AzureBlob.url("folder/blob.txt", ctx) ==
               "http://127.0.0.1:10000/devstoreaccount1/uploads/folder/blob.txt"
    end

    test "generates a SAS URL from an account key" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          account_key: @account_key,
          presigned: true,
          expires_in: 60
        )

      url = AzureBlob.url("folder/my file.txt", ctx)
      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert uri.scheme == "https"
      assert uri.host == "myaccount.blob.core.windows.net"
      assert uri.path == "/uploads/folder/my%20file.txt"
      assert params["sv"] == "2020-12-06"
      assert params["spr"] == "https"
      assert params["sr"] == "b"
      assert params["sp"] == "r"
      assert params["se"]

      assert params["sig"] ==
               expected_signature(
                 "r",
                 params["se"],
                 "/blob/myaccount/uploads/folder/my file.txt",
                 "https"
               )
    end

    test "includes response header overrides in SAS signatures" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          account_key: @account_key,
          presigned: true,
          content_type: "image/png",
          disposition: :attachment,
          filename: "photo.png"
        )

      url = AzureBlob.url("photo.png", ctx)
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["rsct"] == "image/png"
      assert params["rscd"] == ~s(attachment; filename="photo.png")

      assert params["sig"] ==
               expected_signature(
                 "r",
                 params["se"],
                 "/blob/myaccount/uploads/photo.png",
                 "https",
                 %{"rscd" => ~s(attachment; filename="photo.png"), "rsct" => "image/png"}
               )
    end

    test "uses configured SAS tokens" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          sas_token: "?sv=2020-12-06&sp=r&sig=abc123",
          presigned: true
        )

      assert AzureBlob.url("blob.txt", ctx) ==
               "https://myaccount.blob.core.windows.net/uploads/blob.txt?sv=2020-12-06&sp=r&sig=abc123"
    end

    test "raises a helpful error when a presigned URL lacks credentials" do
      ctx = Context.new(account: @account, container: @container, presigned: true)

      assert_raise ArgumentError,
                   ~r/could not generate Azure Blob SAS URL: :missing_credentials/,
                   fn ->
                     AzureBlob.url("blob.txt", ctx)
                   end
    end
  end

  describe "direct_upload/2" do
    test "generates a presigned PUT URL with Azure-required headers" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          account_key: @account_key,
          content_type: "image/png"
        )

      assert {:ok, %{url: url, method: :put, headers: headers}} =
               AzureBlob.direct_upload("folder/photo.png", ctx)

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["sp"] == "cw"
      assert params["sr"] == "b"
      assert headers["x-ms-blob-type"] == "BlockBlob"
      assert headers["content-type"] == "image/png"
    end

    test "uses configured SAS tokens" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          sas_token: "?sv=2020-12-06&sp=cw&sig=abc123"
        )

      assert {:ok, %{url: url, method: :put, headers: headers}} =
               AzureBlob.direct_upload("blob.txt", ctx)

      assert url ==
               "https://myaccount.blob.core.windows.net/uploads/blob.txt?sv=2020-12-06&sp=cw&sig=abc123"

      assert headers["x-ms-blob-type"] == "BlockBlob"
    end

    test "allows http endpoints by default for Azurite" do
      ctx =
        Context.new(
          account: "devstoreaccount1",
          container: @container,
          account_key: @account_key,
          endpoint_url: "http://127.0.0.1:10000/devstoreaccount1"
        )

      assert {:ok, %{url: url}} = AzureBlob.direct_upload("folder/photo.png", ctx)

      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert uri.scheme == "http"
      assert uri.path == "/devstoreaccount1/uploads/folder/photo.png"
      assert params["spr"] == "https,http"
    end

    test "returns an error without credentials" do
      ctx = Context.new(account: @account, container: @container)

      assert {:error, :missing_credentials} = AzureBlob.direct_upload("blob.txt", ctx)
    end
  end

  describe "configured SAS token permissions" do
    test "direct_upload/2 fails fast when the configured token lacks create/write" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          sas_token: "?sv=2020-12-06&sp=r&sig=abc123"
        )

      assert {:error, {:sas_missing_permissions, details}} =
               AzureBlob.direct_upload("blob.txt", ctx)

      assert details[:required] == "cw"
      assert details[:granted] == "r"
      assert details[:missing] in ["cw", "wc"]
    end

    test "url/2 raises a helpful error when the presign token lacks read" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          sas_token: "?sv=2020-12-06&sp=cw&sig=abc123",
          presigned: true
        )

      assert_raise ArgumentError, ~r/sas_missing_permissions/, fn ->
        AzureBlob.url("blob.txt", ctx)
      end
    end

    test "tokens with broader permissions are accepted for narrower operations" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          sas_token: "?sv=2020-12-06&sp=racwdl&sig=abc123",
          presigned: true
        )

      assert {:ok, %{url: url}} = AzureBlob.direct_upload("blob.txt", ctx)
      assert url =~ "sp=racwdl"
      assert AzureBlob.url("blob.txt", ctx) =~ "sp=racwdl"
    end

    test "tokens without an `sp` parameter fall through to Azure" do
      ctx =
        Context.new(
          account: @account,
          container: @container,
          sas_token: "?sv=2020-12-06&sig=abc123",
          presigned: true
        )

      assert AzureBlob.url("blob.txt", ctx) =~ "sig=abc123"
      assert {:ok, _} = AzureBlob.direct_upload("blob.txt", ctx)
    end
  end

  describe "HTTP storage operations" do
    setup do
      start_mock_azure()
    end

    test "upload, download, exists?, and delete round-trip through HTTP", %{
      endpoint_url: endpoint_url,
      server_state: server_state
    } do
      ctx = http_context(endpoint_url)
      key = "folder/hello.txt"

      assert :ok = AzureBlob.upload(key, "hello azure", ctx)
      assert {:ok, true} = AzureBlob.exists?(key, ctx)
      assert {:ok, "hello azure"} = AzureBlob.download(key, ctx)
      assert :ok = AzureBlob.delete(key, ctx)
      assert {:ok, false} = AzureBlob.exists?(key, ctx)
      assert {:error, :not_found} = AzureBlob.download(key, ctx)

      [put_request, head_request, get_request, delete_request, missing_head, missing_get] =
        recorded_requests(server_state)

      assert put_request.method == "PUT"
      assert put_request.path == "/devstoreaccount1/uploads/folder/hello.txt"
      assert put_request.query["sp"] == "cw"
      assert put_request.headers["x-ms-blob-type"] == "BlockBlob"
      assert put_request.headers["x-ms-version"] == "2020-12-06"
      assert put_request.body == "hello azure"

      assert head_request.method == "HEAD"
      assert head_request.query["sp"] == "r"

      assert get_request.method == "GET"
      assert get_request.query["sp"] == "r"

      assert delete_request.method == "DELETE"
      assert delete_request.query["sp"] == "d"

      assert missing_head.method == "HEAD"
      assert missing_get.method == "GET"
    end

    test "direct upload URL works with returned headers", %{endpoint_url: endpoint_url} do
      ctx = http_context(endpoint_url, content_type: "image/png")

      assert {:ok, %{url: url, method: :put, headers: headers}} =
               AzureBlob.direct_upload("direct/photo.png", ctx)

      assert headers["x-ms-blob-type"] == "BlockBlob"
      assert headers["content-type"] == "image/png"
      assert {:ok, %{status: 201}} = Req.put(url, body: "image data", headers: headers)
      assert {:ok, "image data"} = AzureBlob.download("direct/photo.png", ctx)
    end
  end

  describe "service_opts_fields/0" do
    test "declares fields needed to persist service options" do
      fields = AzureBlob.service_opts_fields()

      assert fields[:account][:allow_nil?] == false
      assert fields[:container][:allow_nil?] == false
      assert fields[:account_key_env][:type] == :string
      assert fields[:sas_token_env][:type] == :string
      refute Keyword.has_key?(fields, :account_key)
      refute Keyword.has_key?(fields, :sas_token)
    end
  end

  defp http_context(endpoint_url, extra_opts \\ []) do
    Context.new(
      Keyword.merge(
        [
          account: "devstoreaccount1",
          container: @container,
          account_key: @account_key,
          endpoint_url: endpoint_url
        ],
        extra_opts
      )
    )
  end

  defp start_mock_azure do
    {:ok, server_state} = Agent.start(fn -> %{objects: %{}, requests: []} end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    acceptor = spawn(fn -> accept_loop(listener, server_state) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(acceptor, :shutdown)
      Agent.stop(server_state)
    end)

    {:ok, endpoint_url: "http://127.0.0.1:#{port}/devstoreaccount1", server_state: server_state}
  end

  defp accept_loop(listener, server_state) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve_connection(socket, server_state) end)
        accept_loop(listener, server_state)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_connection(socket, server_state) do
    case read_request(socket) do
      {:ok, request} ->
        {status, body} = handle_mock_request(request, server_state)
        send_response(socket, status, body)

      {:error, _reason} ->
        send_response(socket, 400, "")
    end
  after
    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, raw_request} <- recv_until_headers(socket, <<>>),
         [raw_headers, buffered_body] <- :binary.split(raw_request, "\r\n\r\n"),
         [request_line | header_lines] <- String.split(raw_headers, "\r\n"),
         [method, target, _version] <- String.split(request_line, " ", parts: 3) do
      headers = parse_headers(header_lines)
      content_length = headers |> Map.get("content-length", "0") |> String.to_integer()

      with {:ok, body} <- read_body(socket, buffered_body, content_length) do
        uri = URI.parse(target)

        {:ok,
         %{
           method: method,
           path: uri.path,
           query: URI.decode_query(uri.query || ""),
           headers: headers,
           body: body
         }}
      end
    else
      _ -> {:error, :bad_request}
    end
  end

  defp recv_until_headers(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {_start, _length} ->
        {:ok, buffer}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> recv_until_headers(socket, buffer <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_body(_socket, buffered_body, 0), do: {:ok, binary_part(buffered_body, 0, 0)}

  defp read_body(socket, buffered_body, content_length)
       when byte_size(buffered_body) < content_length do
    case :gen_tcp.recv(socket, content_length - byte_size(buffered_body), 5_000) do
      {:ok, chunk} -> read_body(socket, buffered_body <> chunk, content_length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_body(_socket, buffered_body, content_length) do
    {:ok, binary_part(buffered_body, 0, content_length)}
  end

  defp parse_headers(header_lines) do
    Map.new(header_lines, fn line ->
      [name, value] = String.split(line, ":", parts: 2)
      {String.downcase(name), String.trim_leading(value)}
    end)
  end

  defp handle_mock_request(request, server_state) do
    case blob_key_from_path(request.path) do
      {:ok, key} ->
        request = Map.put(request, :key, key)
        record_request(server_state, request)
        handle_blob_request(request, server_state)

      :error ->
        {404, ""}
    end
  end

  defp handle_blob_request(%{method: "PUT"} = request, server_state) do
    cond do
      !has_permission?(request, "w") ->
        {403, ""}

      request.headers["x-ms-blob-type"] != "BlockBlob" ->
        {400, ""}

      true ->
        Agent.update(server_state, fn state ->
          %{state | objects: Map.put(state.objects, request.key, request.body)}
        end)

        {201, ""}
    end
  end

  defp handle_blob_request(%{method: "GET"} = request, server_state) do
    if has_permission?(request, "r") do
      case stored_object(server_state, request.key) do
        {:ok, body} -> {200, body}
        :error -> {404, ""}
      end
    else
      {403, ""}
    end
  end

  defp handle_blob_request(%{method: "HEAD"} = request, server_state) do
    if has_permission?(request, "r") do
      case stored_object(server_state, request.key) do
        {:ok, _body} -> {200, ""}
        :error -> {404, ""}
      end
    else
      {403, ""}
    end
  end

  defp handle_blob_request(%{method: "DELETE"} = request, server_state) do
    if has_permission?(request, "d") do
      existed? =
        Agent.get_and_update(server_state, fn state ->
          {Map.has_key?(state.objects, request.key),
           %{state | objects: Map.delete(state.objects, request.key)}}
        end)

      if existed?, do: {202, ""}, else: {404, ""}
    else
      {403, ""}
    end
  end

  defp handle_blob_request(_request, _server_state), do: {405, ""}

  defp blob_key_from_path(path) do
    case String.split(path || "", "/", trim: true) do
      [_account, _container | key_segments] when key_segments != [] ->
        {:ok, Enum.map_join(key_segments, "/", &URI.decode/1)}

      _ ->
        :error
    end
  end

  defp has_permission?(request, permission) do
    request.query |> Map.get("sp", "") |> String.contains?(permission)
  end

  defp stored_object(server_state, key) do
    Agent.get(server_state, fn state -> Map.fetch(state.objects, key) end)
  end

  defp record_request(server_state, request) do
    Agent.update(server_state, fn state -> %{state | requests: [request | state.requests]} end)
  end

  defp recorded_requests(server_state) do
    Agent.get(server_state, fn state -> Enum.reverse(state.requests) end)
  end

  defp send_response(socket, status, body) do
    response = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason_phrase(status),
      "\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: close\r\n\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(201), do: "Created"
  defp reason_phrase(202), do: "Accepted"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"

  defp expected_signature(
         permissions,
         expiry,
         canonicalized_resource,
         protocol,
         response_headers \\ %{}
       ) do
    string_to_sign =
      [
        permissions,
        "",
        expiry,
        canonicalized_resource,
        "",
        "",
        protocol,
        "2020-12-06",
        "b",
        "",
        "",
        Map.get(response_headers, "rscc", ""),
        Map.get(response_headers, "rscd", ""),
        Map.get(response_headers, "rsce", ""),
        Map.get(response_headers, "rscl", ""),
        Map.get(response_headers, "rsct", "")
      ]
      |> Enum.join("\n")

    :crypto.mac(:hmac, :sha256, "test account key", string_to_sign)
    |> Base.encode64()
  end
end
