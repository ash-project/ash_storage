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
