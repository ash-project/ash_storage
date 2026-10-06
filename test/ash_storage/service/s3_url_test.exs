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

  test "URLs use the S3 endpoint when no public base URL is set" do
    assert S3.url("key", context(prefix: "uploads/")) ==
             "https://s3.example.com/test-bucket/uploads/key"

    assert S3.url("key", context(public_base_url: "", prefix: "uploads/")) ==
             "https://s3.example.com/test-bucket/uploads/key"
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

  test "presigned URLs ignore the public base URL" do
    ctx =
      context(
        public_base_url: "https://cdn.example.com",
        prefix: "uploads/",
        presigned: true,
        access_key_id: "test-access-key",
        secret_access_key: "test-secret-key"
      )

    uri = "key" |> S3.url(ctx) |> URI.parse()

    assert uri.host == "s3.example.com"
    assert uri.path == "/test-bucket/uploads/key"
    assert URI.decode_query(uri.query)["X-Amz-Signature"]
  end
end
