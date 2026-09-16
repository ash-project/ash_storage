defmodule AshStorage.Service.S3Test do
  # Mutates application config and the environment; keep it out of the async pool.
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Service.{Context, S3}
  alias AshStorage.Test.{Blob, ConfigurablePost}

  defmodule StaticCredentials do
    @moduledoc false
    # The recipe from the S3 moduledoc: static credentials from app config,
    # merged in on every call, so nothing secret is persisted or read from
    # the environment — including on paths that start from a blob row.
    @behaviour AshStorage.Service
    alias AshStorage.Service.S3

    defdelegate service_opts_fields, to: S3

    def upload(key, data, ctx), do: S3.upload(key, data, with_credentials(ctx))
    def download(key, ctx), do: S3.download(key, with_credentials(ctx))
    def delete(key, ctx), do: S3.delete(key, with_credentials(ctx))
    def exists?(key, ctx), do: S3.exists?(key, with_credentials(ctx))
    def head(key, ctx), do: S3.head(key, with_credentials(ctx))
    def url(key, ctx), do: S3.url(key, with_credentials(ctx))
    def direct_upload(key, ctx), do: S3.direct_upload(key, with_credentials(ctx))

    defp with_credentials(ctx) do
      credentials = Application.fetch_env!(:ash_storage, :s3_test_static_credentials)
      %{ctx | service_opts: Keyword.merge(ctx.service_opts, credentials)}
    end
  end

  @env ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_TEST_ACCESS_KEY_ID S3_TEST_SECRET_ACCESS_KEY)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Application.delete_env(:ash_storage, ConfigurablePost)
      Enum.each(saved, fn {name, value} -> restore_env(name, value) end)
    end)

    :ok
  end

  defp configure!(opts) do
    Application.put_env(:ash_storage, ConfigurablePost,
      storage: [service: {S3, Keyword.merge([bucket: "test-bucket", region: "us-east-1"], opts)}]
    )
  end

  # The SigV4 presign is computed locally, so no network is involved.
  defp prepare! do
    {:ok, %{blob: blob}} =
      Operations.prepare_direct_upload(ConfigurablePost, :avatar,
        filename: "photo.jpg",
        content_type: "image/jpeg",
        byte_size: 123
      )

    Blob |> Ash.get!(blob.id) |> Ash.load!(:parsed_service_opts)
  end

  defp persisted(row), do: Map.new(row.service_opts || %{}, fn {k, v} -> {to_string(k), v} end)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  describe "credentials never round-trip onto the blob row" do
    test "service_opts_fields/0 persists the env-var names, not the raw keys" do
      keys = Keyword.keys(S3.service_opts_fields())

      refute :access_key_id in keys
      refute :secret_access_key in keys
      assert :access_key_id_env in keys
      assert :secret_access_key_env in keys
      assert :bucket in keys
    end

    test "inline credentials are not persisted by a direct-upload preparation" do
      configure!(
        access_key_id: "AKIAINLINEEXAMPLE",
        secret_access_key: "inline-secret-must-not-persist"
      )

      assert persisted(prepare!()) == %{"bucket" => "test-bucket", "region" => "us-east-1"}
    end
  end

  describe "credentials resolve as AzureBlob's do" do
    test "a raw value wins for the call that carries it" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIAENVDEFAULT")
      System.put_env("AWS_SECRET_ACCESS_KEY", "env-secret")

      ctx =
        Context.new(
          bucket: "test-bucket",
          region: "us-east-1",
          access_key_id: "AKIAINLINE",
          secret_access_key: "inline"
        )

      assert {:ok, %{url: url}} = S3.direct_upload("k", ctx)
      assert url =~ "X-Amz-Credential=AKIAINLINE"
    end

    test "the persisted env-var names carry an operation that starts from the row" do
      configure!(
        access_key_id_env: "S3_TEST_ACCESS_KEY_ID",
        secret_access_key_env: "S3_TEST_SECRET_ACCESS_KEY",
        access_key_id: "AKIAINLINE",
        secret_access_key: "inline"
      )

      row = prepare!()

      assert persisted(row) == %{
               "bucket" => "test-bucket",
               "region" => "us-east-1",
               "access_key_id_env" => "S3_TEST_ACCESS_KEY_ID",
               "secret_access_key_env" => "S3_TEST_SECRET_ACCESS_KEY"
             }

      System.put_env("S3_TEST_ACCESS_KEY_ID", "AKIAFROMENV")
      System.put_env("S3_TEST_SECRET_ACCESS_KEY", "secret-from-env")

      # Exactly what a purge job, an analyzer or a variant read has: the row alone.
      ctx = Context.new(row.parsed_service_opts)

      assert {:ok, %{url: url}} = S3.direct_upload(row.key, ctx)
      assert url =~ "X-Amz-Credential=AKIAFROMENV"
    end

    test "without names, the AWS defaults apply" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIAENVDEFAULT")
      System.put_env("AWS_SECRET_ACCESS_KEY", "env-secret")

      ctx = Context.new(bucket: "test-bucket", region: "us-east-1")

      assert {:ok, %{url: url}} = S3.direct_upload("k", ctx)
      assert url =~ "X-Amz-Credential=AKIAENVDEFAULT"
    end

    test "nothing resolvable is an error, not a crash" do
      ctx = Context.new(bucket: "test-bucket", region: "us-east-1")

      assert {:error, :missing_credentials} = S3.download("k", ctx)
      assert {:error, :missing_credentials} = S3.exists?("k", ctx)
      assert {:error, :missing_credentials} = S3.direct_upload("k", ctx)

      assert_raise ArgumentError, ~r/could not generate S3 presigned URL/, fn ->
        S3.url("k", Context.new(bucket: "test-bucket", presigned: true))
      end
    end
  end

  describe "static credentials without environment variables (the documented recipe)" do
    test "an app-side service carries them to an operation that starts from the row" do
      Application.put_env(:ash_storage, :s3_test_static_credentials,
        access_key_id: "AKIASTATIC",
        secret_access_key: "static-secret"
      )

      on_exit(fn -> Application.delete_env(:ash_storage, :s3_test_static_credentials) end)

      Application.put_env(:ash_storage, ConfigurablePost,
        storage: [service: {StaticCredentials, bucket: "test-bucket", region: "us-east-1"}]
      )

      row = prepare!()
      assert row.service_name == StaticCredentials
      assert persisted(row) == %{"bucket" => "test-bucket", "region" => "us-east-1"}

      # No environment at all (the setup cleared AWS_*): the row alone.
      ctx = Context.new(row.parsed_service_opts)
      assert {:ok, %{url: url}} = StaticCredentials.direct_upload(row.key, ctx)
      assert url =~ "X-Amz-Credential=AKIASTATIC"
    end
  end
end
