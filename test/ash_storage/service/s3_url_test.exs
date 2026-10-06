defmodule AshStorage.Service.S3UrlTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.{Context, S3}

  defp context(opts \\ []) do
    Context.new(
      Keyword.merge(
        [bucket: "test-bucket", region: "us-east-1", endpoint_url: "https://s3.example.com"],
        opts
      )
    )
  end

  test "unsigned URLs are unchanged without a public base URL" do
    assert S3.url("key", context()) == "https://s3.example.com/test-bucket/key"

    assert S3.url("key", context(public_base_url: nil, prefix: "uploads/", presigned: false)) ==
             "https://s3.example.com/test-bucket/uploads/key"

    assert S3.url("key", context(endpoint_url: nil)) ==
             "https://s3.us-east-1.amazonaws.com/test-bucket/key"
  end

  test "public URLs join the base path, prefix, and key without adding the bucket" do
    for {base_url, prefix, path} <- [
          {"https://cdn.example.com", nil, "/key"},
          {"https://cdn.example.com/", "uploads/", "/uploads/key"},
          {"https://cdn.example.com/media", "uploads/", "/media/uploads/key"},
          {"https://cdn.example.com/media/", "", "/media/key"}
        ] do
      assert S3.url("key", context(public_base_url: base_url, prefix: prefix)) ==
               "https://cdn.example.com" <> path
    end
  end

  test "public URLs encode the prefix and key while preserving path separators" do
    ctx = context(public_base_url: "https://cdn.example.com", prefix: "food photos/")

    assert S3.url("nested/café +?#%.png", ctx) ==
             "https://cdn.example.com/food%20photos/nested/caf%C3%A9%20%2B%3F%23%25.png"
  end

  test "presigned GET URLs ignore the public base URL" do
    ctx =
      context(
        public_base_url: "https://cdn.example.com",
        prefix: "uploads/",
        presigned: true,
        expires_in: 300,
        access_key_id: "test-access-key",
        secret_access_key: "test-secret-key"
      )

    uri = "key" |> S3.url(ctx) |> URI.parse()
    query = URI.decode_query(uri.query)

    assert uri.host == "s3.example.com"
    assert uri.path == "/test-bucket/uploads/key"
    assert query["X-Amz-Expires"] == "300"
    assert query["X-Amz-Signature"]
  end

  test "direct PUT and POST uploads still target the S3 API" do
    opts = [
      public_base_url: "https://cdn.example.com",
      prefix: "uploads/",
      presigned: false,
      access_key_id: "test-access-key",
      secret_access_key: "test-secret-key"
    ]

    assert {:ok, %{method: :put, url: url}} = S3.direct_upload("key", context(opts))
    uri = URI.parse(url)
    assert uri.host == "s3.example.com"
    assert uri.path == "/test-bucket/uploads/key"
    assert URI.decode_query(uri.query)["X-Amz-Signature"]

    assert {:ok, %{method: :post, url: url, fields: fields}} =
             S3.direct_upload("key", context(Keyword.put(opts, :direct_upload_method, :post)))

    uri = URI.parse(url)
    fields = Map.new(fields)
    assert uri.host == "s3.example.com"
    assert uri.path == "/test-bucket"
    assert fields["key"] == "uploads/key"
    assert fields["x-amz-signature"]
  end
end
