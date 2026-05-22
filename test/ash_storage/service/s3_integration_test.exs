defmodule AshStorage.Service.S3IntegrationTest do
  @moduledoc """
  Integration tests for AshStorage.Service.S3 against a real MinIO instance.

  These tests start a MinIO container via Docker, run the tests, and clean up.
  Requires Docker to be available. Tagged with :s3_integration so they can be
  excluded from normal test runs.
  """
  use ExUnit.Case, async: false

  alias AshStorage.Service.Context
  alias AshStorage.Service.S3

  @moduletag :s3_integration

  @bucket "ash-storage-test"
  @port 19_000
  @container_name "ash_storage_minio_test"

  @service_opts [
    bucket: @bucket,
    region: "us-east-1",
    access_key_id: "minioadmin",
    secret_access_key: "minioadmin",
    endpoint_url: "http://localhost:#{@port}"
  ]

  setup_all do
    # Stop any leftover container from a previous run
    System.cmd("docker", ["rm", "-f", @container_name], stderr_to_stdout: true)

    # Start MinIO
    {_, 0} =
      System.cmd("docker", [
        "run",
        "-d",
        "--name",
        @container_name,
        "-p",
        "#{@port}:9000",
        "-e",
        "MINIO_ROOT_USER=minioadmin",
        "-e",
        "MINIO_ROOT_PASSWORD=minioadmin",
        "minio/minio",
        "server",
        "/data"
      ])

    # Wait for MinIO to be ready
    :ok = wait_for_minio(30)

    # Create the test bucket
    :ok = create_bucket()

    on_exit(fn ->
      System.cmd("docker", ["rm", "-f", @container_name], stderr_to_stdout: true)
    end)

    :ok
  end

  defp ctx(extra_opts \\ []) do
    Context.new(Keyword.merge(@service_opts, extra_opts))
  end

  describe "upload/3 and download/2" do
    test "round-trips binary data" do
      key = unique_key()
      assert :ok = S3.upload(key, "hello s3", ctx())
      assert {:ok, "hello s3"} = S3.download(key, ctx())
    end

    test "round-trips iolist data" do
      key = unique_key()
      assert :ok = S3.upload(key, ["hello", " ", "s3"], ctx())
      assert {:ok, "hello s3"} = S3.download(key, ctx())
    end

    test "round-trips binary data (large)" do
      key = unique_key()
      data = :crypto.strong_rand_bytes(1024 * 100)
      assert :ok = S3.upload(key, data, ctx())
      assert {:ok, ^data} = S3.download(key, ctx())
    end

    test "download returns not_found for missing key" do
      assert {:error, :not_found} = S3.download(unique_key(), ctx())
    end

    test "round-trips bytes uploaded with a CSV content-type without auto-decoding" do
      key = unique_key()
      csv = "Name,Score\nAlice,95\nBob,87\n"

      :ok = raw_put_with_content_type(key, csv, "text/csv")
      assert {:ok, ^csv} = S3.download(key, ctx())
    end

    test "decode_body: true opts back into Req's content-type decoding" do
      key = unique_key()
      json = ~s({"name":"Alice","score":95})

      :ok = raw_put_with_content_type(key, json, "application/json")

      assert {:ok, %{"name" => "Alice", "score" => 95}} =
               S3.download(key, ctx(decode_body: true))
    end

    test "accepts upload when ctx expected_md5 matches the body" do
      key = unique_key()
      data = "checksum-verified payload"
      ctx = Context.put_expected_md5(ctx(), Base.encode64(:crypto.hash(:md5, data)))

      assert :ok = S3.upload(key, data, ctx)
      assert {:ok, ^data} = S3.download(key, ctx())
    end

    test "rejects upload when ctx expected_md5 doesn't match the body" do
      key = unique_key()
      ctx = Context.put_expected_md5(ctx(), Base.encode64(:crypto.hash(:md5, "other")))

      assert {:error, {400, _body}} = S3.upload(key, "actual", ctx)
      assert {:ok, false} = S3.exists?(key, ctx())
    end
  end

  describe "exists?/2" do
    test "returns true for existing key" do
      key = unique_key()
      S3.upload(key, "data", ctx())
      assert {:ok, true} = S3.exists?(key, ctx())
    end

    test "returns false for missing key" do
      assert {:ok, false} = S3.exists?(unique_key(), ctx())
    end
  end

  describe "delete/2" do
    test "deletes an existing object" do
      key = unique_key()
      S3.upload(key, "data", ctx())
      assert {:ok, true} = S3.exists?(key, ctx())

      assert :ok = S3.delete(key, ctx())
      assert {:ok, false} = S3.exists?(key, ctx())
    end

    test "succeeds for missing key" do
      assert :ok = S3.delete(unique_key(), ctx())
    end
  end

  describe "url/2" do
    test "generates a public URL" do
      key = unique_key()
      url = S3.url(key, ctx())
      assert url == "http://localhost:#{@port}/#{@bucket}/#{key}"
    end

    test "generates a presigned URL that works" do
      key = unique_key()
      S3.upload(key, "presigned content", ctx())

      url = S3.url(key, ctx(presigned: true))
      assert url =~ "X-Amz-Signature"

      # Actually fetch via the presigned URL
      assert {:ok, %{status: 200, body: "presigned content"}} = Req.get(url)
    end

    test "presigned URL respects expires_in" do
      key = unique_key()
      S3.upload(key, "expiry test", ctx())

      url = S3.url(key, ctx(presigned: true, expires_in: 60))
      assert url =~ "X-Amz-Signature"
      assert url =~ "X-Amz-Expires=60"

      assert {:ok, %{status: 200, body: "expiry test"}} = Req.get(url)
    end
  end

  describe "prefix option" do
    test "prefixes keys in storage" do
      key = unique_key()
      prefixed_ctx = ctx(prefix: "uploads/")

      assert :ok = S3.upload(key, "prefixed data", prefixed_ctx)
      assert {:ok, "prefixed data"} = S3.download(key, prefixed_ctx)

      # The actual S3 key should be prefixed
      assert {:ok, "prefixed data"} =
               S3.download("uploads/#{key}", ctx())
    end
  end

  describe "Proxy plug with S3" do
    test "serves file through proxy" do
      key = unique_key()
      S3.upload(key, "proxy s3 content", ctx())

      plug_opts =
        AshStorage.Plug.Proxy.init(service: {AshStorage.Service.S3, @service_opts})

      conn =
        Plug.Test.conn(:get, "/#{key}")
        |> AshStorage.Plug.Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body == "proxy s3 content"
    end

    test "returns 404 for missing key through proxy" do
      plug_opts =
        AshStorage.Plug.Proxy.init(service: {AshStorage.Service.S3, @service_opts})

      conn =
        Plug.Test.conn(:get, "/#{unique_key()}")
        |> AshStorage.Plug.Proxy.call(plug_opts)

      assert conn.status == 404
    end

    test "signed proxy rejects unsigned requests" do
      key = unique_key()
      S3.upload(key, "secret data", ctx())

      plug_opts =
        AshStorage.Plug.Proxy.init(
          service: {AshStorage.Service.S3, @service_opts},
          secret: "proxy-test-secret"
        )

      conn =
        Plug.Test.conn(:get, "/#{key}")
        |> AshStorage.Plug.Proxy.call(plug_opts)

      assert conn.status == 403
    end

    test "signed proxy serves with valid token" do
      key = unique_key()
      S3.upload(key, "signed proxy data", ctx())
      secret = "proxy-test-secret"
      expires = System.system_time(:second) + 3600
      token = AshStorage.Token.sign(secret, key, expires)

      plug_opts =
        AshStorage.Plug.Proxy.init(
          service: {AshStorage.Service.S3, @service_opts},
          secret: secret
        )

      conn =
        Plug.Test.conn(
          :get,
          "/#{key}?token=#{URI.encode_www_form(token)}&expires=#{expires}"
        )
        |> Plug.Conn.fetch_query_params()
        |> AshStorage.Plug.Proxy.call(plug_opts)

      assert conn.status == 200
      assert conn.resp_body == "signed proxy data"
    end
  end

  describe "end-to-end with Operations" do
    setup do
      AshStorage.Service.Test.reset!()
      :ok
    end

    test "attach and load via S3" do
      # ConfigurablePost has otp_app: :ash_storage, so config overrides work
      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          service: {AshStorage.Service.S3, @service_opts}
        ]
      )

      post =
        AshStorage.Test.ConfigurablePost
        |> Ash.Changeset.for_create(:create, %{title: "s3 post"})
        |> Ash.create!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :avatar, "s3 file content",
          filename: "s3test.txt",
          content_type: "text/plain"
        )

      assert blob.filename == "s3test.txt"
      assert blob.service_name == AshStorage.Service.S3

      # Verify file is actually in S3
      assert {:ok, "s3 file content"} = S3.download(blob.key, ctx())

      # Load the attachment via Ash
      post = Ash.load!(post, avatar: :blob)
      assert post.avatar.blob.key == blob.key

      # URL calculation should return S3 URL
      post = Ash.load!(post, :avatar_url)
      assert post.avatar_url == "http://localhost:#{@port}/#{@bucket}/#{blob.key}"

      # Presigned URL calculation via config override
      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          service: {AshStorage.Service.S3, Keyword.put(@service_opts, :presigned, true)}
        ]
      )

      # Re-read the post to clear cached calculations
      post = Ash.get!(AshStorage.Test.ConfigurablePost, post.id)
      post = Ash.load!(post, :avatar_url)
      assert post.avatar_url =~ "X-Amz-Signature"

      # Reset to plain URLs for purge
      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          service: {AshStorage.Service.S3, @service_opts}
        ]
      )

      # Purge should remove from S3
      {:ok, _} = AshStorage.Operations.purge(post, :avatar)
      assert {:ok, false} = S3.exists?(blob.key, ctx())
    after
      Application.delete_env(:ash_storage, AshStorage.Test.ConfigurablePost)
    end

    test "direct upload flow via S3" do
      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          service: {AshStorage.Service.S3, @service_opts}
        ]
      )

      # Step 1: Prepare direct upload — creates blob, gets presigned URL
      {:ok, %{blob: blob, url: upload_url, method: :put}} =
        AshStorage.Operations.prepare_direct_upload(
          AshStorage.Test.ConfigurablePost,
          :avatar,
          filename: "direct.txt",
          content_type: "text/plain",
          byte_size: 14
        )

      assert blob.filename == "direct.txt"
      assert blob.service_name == AshStorage.Service.S3
      assert upload_url != nil

      # Step 2: Client uploads directly to S3 using presigned PUT URL
      assert {:ok, %{status: status}} = Req.put(upload_url, body: "direct content")
      assert status in [200, 204]

      # Step 3: Create record and attach the blob
      post =
        AshStorage.Test.ConfigurablePost
        |> Ash.Changeset.for_create(:create, %{title: "direct upload post"})
        |> Ash.create!()

      post =
        post
        |> Ash.Changeset.for_update(:attach_avatar_blob, %{avatar_blob_id: blob.id})
        |> Ash.update!()

      # Verify file is actually in S3
      assert {:ok, "direct content"} = S3.download(blob.key, ctx())

      # Verify loadable via Ash
      post = Ash.load!(post, avatar: :blob)
      assert post.avatar.blob.filename == "direct.txt"
    after
      Application.delete_env(:ash_storage, AshStorage.Test.ConfigurablePost)
    end
  end

  # -- Helpers --

  defp raw_put_with_content_type(key, body, content_type) do
    url = "#{@service_opts[:endpoint_url]}/#{@bucket}/#{key}"

    {:ok, %{status: status}} =
      Req.put(url,
        body: body,
        headers: %{"content-type" => content_type},
        aws_sigv4: [
          service: :s3,
          region: @service_opts[:region],
          access_key_id: @service_opts[:access_key_id],
          secret_access_key: @service_opts[:secret_access_key]
        ]
      )

    if status in 200..299, do: :ok, else: {:error, status}
  end

  defp unique_key do
    "test/#{System.unique_integer([:positive])}-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
  end

  defp wait_for_minio(0), do: {:error, :timeout}

  defp wait_for_minio(attempts) do
    case Req.get("http://localhost:#{@port}/minio/health/ready") do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        Process.sleep(1000)
        wait_for_minio(attempts - 1)
    end
  end

  defp create_bucket do
    sigv4_opts = [
      service: :s3,
      region: "us-east-1",
      access_key_id: "minioadmin",
      secret_access_key: "minioadmin"
    ]

    case Req.put("http://localhost:#{@port}/#{@bucket}",
           aws_sigv4: sigv4_opts,
           body: ""
         ) do
      {:ok, %{status: status}} when status in [200, 409] -> :ok
      other -> {:error, other}
    end
  end
end
