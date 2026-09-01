defmodule AshStorage.Service.S3Test do
  use ExUnit.Case, async: true

  # The S3 service is compiled only when ReqS3 is available.
  if Code.ensure_loaded?(AshStorage.Service.S3) do
    alias AshStorage.BlobIO.Support
    alias AshStorage.Service.S3

    describe "credentials never round-trip onto the blob row (SR9)" do
      test "service_opts_fields/0 excludes raw secret keys" do
        keys = Keyword.keys(S3.service_opts_fields())

        refute :access_key_id in keys
        refute :secret_access_key in keys

        # Non-secret descriptors are still persistable.
        assert :bucket in keys
        assert :region in keys
        assert :endpoint_url in keys
      end

      test "an inlined secret is dropped from the persistable opts" do
        persistable =
          Support.persistable_service_opts(S3,
            bucket: "my-bucket",
            region: "us-east-1",
            access_key_id: "AKIAEXAMPLE",
            secret_access_key: "super-secret"
          )

        refute Map.has_key?(persistable, :access_key_id)
        refute Map.has_key?(persistable, :secret_access_key)
        assert persistable[:bucket] == "my-bucket"
        assert persistable[:region] == "us-east-1"
      end
    end
  end
end
