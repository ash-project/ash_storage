defmodule AshStorage.Service.AzureBlobIntegrationTest do
  @moduledoc """
  Integration tests for AshStorage.Service.AzureBlob against a real Azurite instance.

  These tests start an Azurite container via Docker, run the tests, and clean up.
  Requires Docker to be available. Tagged with :azure_integration so they can be
  excluded from normal test runs.
  """
  use ExUnit.Case, async: false

  alias AshStorage.Service.AzureBlob
  alias AshStorage.Service.Context

  @moduletag :azure_integration

  if is_nil(System.find_executable("docker")) do
    @moduletag skip: "Docker is required to run Azure Blob integration tests"
  end

  @account "ashstorage"
  @account_key Base.encode64(:binary.copy("azurite-test-key", 4))
  @account_key_env "AZURE_STORAGE_ACCOUNT_KEY"
  @container "uploads"
  @port 19_001
  @container_name "ash_storage_azurite_test"
  @service_version "2020-12-06"
  @endpoint_url "http://127.0.0.1:19001/ashstorage"

  @service_opts [
    account: @account,
    container: @container,
    account_key_env: @account_key_env,
    endpoint_url: @endpoint_url
  ]

  setup_all do
    previous_account_key = System.get_env(@account_key_env)
    System.put_env(@account_key_env, @account_key)

    on_exit(fn ->
      cleanup_azurite()
      restore_env(@account_key_env, previous_account_key)
    end)

    # Stop any leftover container from a previous run.
    cleanup_azurite()

    # Start Azurite with a deterministic test account/key so SAS signatures are stable.
    case start_azurite() do
      :ok ->
        :ok = wait_for_azurite(30)
        :ok = create_container()
        :ok

      {:error, {status, output}} ->
        cleanup_azurite()

        raise "Could not start Azurite Docker container (exit #{status}): #{String.trim(output)}"
    end
  end

  defp ctx(extra_opts \\ []) do
    Context.new(Keyword.merge(@service_opts, extra_opts))
  end

  defp start_azurite do
    case System.cmd(
           "docker",
           [
             "run",
             "-d",
             "--name",
             @container_name,
             "-p",
             "#{@port}:10000",
             "-e",
             "AZURITE_ACCOUNTS=#{@account}:#{@account_key}",
             "mcr.microsoft.com/azure-storage/azurite",
             "azurite-blob",
             "--blobHost",
             "0.0.0.0",
             "--blobPort",
             "10000"
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, status} -> {:error, {status, output}}
    end
  end

  defp cleanup_azurite do
    System.cmd("docker", ["rm", "-f", @container_name], stderr_to_stdout: true)
    :ok
  end

  defp restore_env(env_var, nil), do: System.delete_env(env_var)
  defp restore_env(env_var, value), do: System.put_env(env_var, value)

  describe "upload/3 and download/2" do
    test "round-trips binary data" do
      key = unique_key()
      assert :ok = AzureBlob.upload(key, "hello azure", ctx())
      assert {:ok, "hello azure"} = AzureBlob.download(key, ctx())
    end

    test "round-trips iolist data" do
      key = unique_key()
      assert :ok = AzureBlob.upload(key, ["hello", " ", "azure"], ctx())
      assert {:ok, "hello azure"} = AzureBlob.download(key, ctx())
    end

    test "round-trips binary data (large)" do
      key = unique_key()
      data = :crypto.strong_rand_bytes(1024 * 1024)
      assert :ok = AzureBlob.upload(key, data, ctx())
      assert {:ok, ^data} = AzureBlob.download(key, ctx())
    end

    test "download returns not_found for missing key" do
      assert {:error, :not_found} = AzureBlob.download(unique_key(), ctx())
    end
  end

  describe "exists?/2" do
    test "returns true for existing key" do
      key = unique_key()
      AzureBlob.upload(key, "data", ctx())
      assert {:ok, true} = AzureBlob.exists?(key, ctx())
    end

    test "returns false for missing key" do
      assert {:ok, false} = AzureBlob.exists?(unique_key(), ctx())
    end
  end

  describe "delete/2" do
    test "deletes an existing blob" do
      key = unique_key()
      AzureBlob.upload(key, "data", ctx())
      assert {:ok, true} = AzureBlob.exists?(key, ctx())

      assert :ok = AzureBlob.delete(key, ctx())
      assert {:ok, false} = AzureBlob.exists?(key, ctx())
    end

    test "succeeds for missing key" do
      assert :ok = AzureBlob.delete(unique_key(), ctx())
    end
  end

  describe "url/2" do
    test "generates a public URL" do
      key = "folder/my file.txt"

      assert AzureBlob.url(key, ctx()) ==
               "#{@endpoint_url}/#{@container}/folder/my%20file.txt"
    end

    test "generates a presigned URL that works" do
      key = unique_key()
      AzureBlob.upload(key, "presigned content", ctx())

      url = AzureBlob.url(key, ctx(presigned: true))
      assert url =~ "sig="

      assert {:ok, %{status: 200, body: "presigned content"}} = Req.get(url)
    end

    test "presigned URL respects expires_in" do
      key = unique_key()
      AzureBlob.upload(key, "expiry test", ctx())

      url = AzureBlob.url(key, ctx(presigned: true, expires_in: 60))
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["se"]
      assert {:ok, %{status: 200, body: "expiry test"}} = Req.get(url)
    end
  end

  describe "prefix option" do
    test "prefixes keys in storage" do
      key = unique_key()
      prefixed_ctx = ctx(prefix: "uploads/")

      assert :ok = AzureBlob.upload(key, "prefixed data", prefixed_ctx)
      assert {:ok, "prefixed data"} = AzureBlob.download(key, prefixed_ctx)

      # The actual Azure blob key should be prefixed.
      assert {:ok, "prefixed data"} = AzureBlob.download("uploads/#{key}", ctx())
    end
  end

  describe "configured SAS tokens" do
    test "work for all operations when the token has the required permissions" do
      key = unique_key()

      sas_ctx =
        @service_opts
        |> Keyword.put(:account_key_env, "MISSING_AZURE_STORAGE_ACCOUNT_KEY")
        |> Keyword.put(:sas_token, blob_sas_token(key, "rcwd"))
        |> Context.new()

      assert :ok = AzureBlob.upload(key, "sas token content", sas_ctx)
      assert {:ok, true} = AzureBlob.exists?(key, sas_ctx)
      assert {:ok, "sas token content"} = AzureBlob.download(key, sas_ctx)
      assert :ok = AzureBlob.delete(key, sas_ctx)
      assert {:ok, false} = AzureBlob.exists?(key, sas_ctx)
    end
  end

  describe "direct_upload/2" do
    test "generates a presigned PUT URL that accepts a browser-style upload" do
      key = unique_key()

      assert {:ok, %{url: upload_url, method: :put, headers: headers}} =
               AzureBlob.direct_upload(key, ctx(content_type: "text/plain"))

      assert headers["x-ms-blob-type"] == "BlockBlob"
      assert headers["content-type"] == "text/plain"

      assert {:ok, %{status: status}} =
               Req.put(upload_url, body: "direct content", headers: headers)

      assert status in 200..299
      assert {:ok, "direct content"} = AzureBlob.download(key, ctx())
    end
  end

  describe "end-to-end with Operations" do
    setup do
      AshStorage.Service.Test.reset!()
      :ok
    end

    test "attach and load via Azure Blob Storage" do
      # ConfigurablePost has otp_app: :ash_storage, so config overrides work.
      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          service: {AshStorage.Service.AzureBlob, @service_opts}
        ]
      )

      post =
        AshStorage.Test.ConfigurablePost
        |> Ash.Changeset.for_create(:create, %{title: "azure post"})
        |> Ash.create!()

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :avatar, "azure file content",
          filename: "azuretest.txt",
          content_type: "text/plain"
        )

      assert blob.filename == "azuretest.txt"
      assert blob.service_name == AshStorage.Service.AzureBlob

      # Verify file is actually in Azure Blob Storage.
      assert {:ok, "azure file content"} = AzureBlob.download(blob.key, ctx())

      # Load the attachment via Ash.
      post = Ash.load!(post, avatar: :blob)
      assert post.avatar.blob.key == blob.key

      # URL calculation should return an Azure Blob URL.
      post = Ash.load!(post, :avatar_url)
      assert post.avatar_url == "#{@endpoint_url}/#{@container}/#{blob.key}"

      # Presigned URL calculation via config override.
      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          service: {AshStorage.Service.AzureBlob, Keyword.put(@service_opts, :presigned, true)}
        ]
      )

      # Re-read the post to clear cached calculations.
      post = Ash.get!(AshStorage.Test.ConfigurablePost, post.id)
      post = Ash.load!(post, :avatar_url)
      assert post.avatar_url =~ "sig="

      # Purge should remove from Azure Blob Storage. The persisted service opts only
      # contain the env var name, so this also verifies env-backed async credentials.
      {:ok, _} = AshStorage.Operations.purge(post, :avatar)
      assert {:ok, false} = AzureBlob.exists?(blob.key, ctx())
    after
      Application.delete_env(:ash_storage, AshStorage.Test.ConfigurablePost)
    end

    test "literal :account_key is not persisted on blob records, breaking async flows" do
      # Regression test for the documented gotcha: literal :account_key works for
      # the immediate request path because the live context has it, but the credential
      # is intentionally excluded from service_opts_fields. Async/blob-driven flows
      # rebuild the context from blob.parsed_service_opts and must therefore fall
      # back to env-backed credentials. Pointing :account_key_env at a deliberately
      # missing env var proves the literal credential never reaches that code path.
      missing_env = "MISSING_AZURE_KEY_FOR_TEST_#{System.unique_integer([:positive])}"
      System.delete_env(missing_env)

      literal_opts =
        @service_opts
        |> Keyword.delete(:account_key_env)
        |> Keyword.put(:account_key, @account_key)
        |> Keyword.put(:account_key_env, missing_env)

      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          service: {AshStorage.Service.AzureBlob, literal_opts}
        ]
      )

      post =
        AshStorage.Test.ConfigurablePost
        |> Ash.Changeset.for_create(:create, %{title: "literal cred post"})
        |> Ash.create!()

      # Attach succeeds — the live changeset context carries the literal account key.
      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :avatar, "literal cred content",
          filename: "literal.txt",
          content_type: "text/plain"
        )

      assert {:ok, "literal cred content"} = AzureBlob.download(blob.key, ctx())

      # The persisted map only contains fields declared in service_opts_fields/0.
      stored_opts = blob.service_opts || %{}
      refute Map.has_key?(stored_opts, :account_key)
      refute Map.has_key?(stored_opts, "account_key")

      # parsed_service_opts is what async/blob-driven flows rebuild a context from.
      blob = Ash.load!(blob, :parsed_service_opts)
      parsed = blob.parsed_service_opts || []
      refute Keyword.has_key?(parsed, :account_key)

      # Calling :purge_blob directly drives the same code path AshOban would.
      # Without an env-backed credential it cannot resolve the account key.
      assert {:error, error} = Ash.destroy(blob, action: :purge_blob, return_destroyed?: true)
      assert Exception.message(error) =~ "missing_credentials"

      # The file is still in storage — clean it up via the env-backed test context.
      assert :ok = AzureBlob.delete(blob.key, ctx())
    after
      Application.delete_env(:ash_storage, AshStorage.Test.ConfigurablePost)
    end

    test "direct upload flow via Azure Blob Storage" do
      Application.put_env(:ash_storage, AshStorage.Test.ConfigurablePost,
        storage: [
          service: {AshStorage.Service.AzureBlob, @service_opts}
        ]
      )

      # Step 1: Prepare direct upload — creates blob, gets presigned URL and headers.
      {:ok, %{blob: blob, url: upload_url, method: :put, headers: headers}} =
        AshStorage.Operations.prepare_direct_upload(
          AshStorage.Test.ConfigurablePost,
          :avatar,
          filename: "direct.txt",
          content_type: "text/plain",
          byte_size: 14
        )

      assert blob.filename == "direct.txt"
      assert blob.service_name == AshStorage.Service.AzureBlob
      assert upload_url =~ "sig="
      assert headers["x-ms-blob-type"] == "BlockBlob"

      # Step 2: Client uploads directly to Azure using the presigned PUT URL.
      assert {:ok, %{status: status}} =
               Req.put(upload_url, body: "direct content", headers: headers)

      assert status in 200..299

      # Step 3: Create record and attach the blob.
      post =
        AshStorage.Test.ConfigurablePost
        |> Ash.Changeset.for_create(:create, %{title: "direct upload post"})
        |> Ash.create!()

      post =
        post
        |> Ash.Changeset.for_update(:attach_avatar_blob, %{avatar_blob_id: blob.id})
        |> Ash.update!()

      # Verify file is actually in Azure Blob Storage.
      assert {:ok, "direct content"} = AzureBlob.download(blob.key, ctx())

      # Verify loadable via Ash.
      post = Ash.load!(post, avatar: :blob)
      assert post.avatar.blob.filename == "direct.txt"
    after
      Application.delete_env(:ash_storage, AshStorage.Test.ConfigurablePost)
    end
  end

  # -- Helpers --

  defp unique_key do
    "test/#{System.unique_integer([:positive])}-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
  end

  defp wait_for_azurite(0), do: {:error, :timeout}

  defp wait_for_azurite(attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, active: false], 1000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      _ ->
        Process.sleep(1000)
        wait_for_azurite(attempts - 1)
    end
  end

  defp create_container(attempts \\ 30)
  defp create_container(0), do: {:error, :timeout}

  defp create_container(attempts) do
    url = "#{@endpoint_url}/#{@container}?restype=container"

    case Req.put(url, headers: shared_key_headers(), body: "") do
      {:ok, %{status: status}} when status in [201, 202, 409] ->
        :ok

      _ ->
        Process.sleep(1000)
        create_container(attempts - 1)
    end
  end

  defp shared_key_headers do
    date = Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")

    canonicalized_headers =
      "x-ms-date:#{date}\nx-ms-version:#{@service_version}\n"

    # Azurite uses path-style URLs, so the account appears both as the signing
    # account and as the first path segment.
    canonicalized_resource = "/#{@account}/#{@account}/#{@container}\nrestype:container"

    string_to_sign =
      [
        "PUT",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        canonicalized_headers <> canonicalized_resource
      ]
      |> Enum.join("\n")

    signature =
      :crypto.mac(:hmac, :sha256, Base.decode64!(@account_key), string_to_sign)
      |> Base.encode64()

    %{
      "authorization" => "SharedKey #{@account}:#{signature}",
      "x-ms-date" => date,
      "x-ms-version" => @service_version
    }
  end

  defp blob_sas_token(key, permissions) do
    protocol = "https,http"
    expiry_time = DateTime.utc_now() |> DateTime.add(3600, :second) |> format_time()
    canonicalized_resource = "/blob/#{@account}/#{@container}/#{key}"

    string_to_sign =
      [
        permissions,
        "",
        expiry_time,
        canonicalized_resource,
        "",
        "",
        protocol,
        @service_version,
        "b",
        "",
        "",
        "",
        "",
        "",
        "",
        ""
      ]
      |> Enum.join("\n")

    signature =
      :crypto.mac(:hmac, :sha256, Base.decode64!(@account_key), string_to_sign)
      |> Base.encode64()

    [
      {"sv", @service_version},
      {"spr", protocol},
      {"se", expiry_time},
      {"sr", "b"},
      {"sp", permissions},
      {"sig", signature}
    ]
    |> URI.encode_query()
  end

  defp format_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
