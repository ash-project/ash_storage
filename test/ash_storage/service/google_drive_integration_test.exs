defmodule AshStorage.Service.GoogleDriveIntegrationTest do
  @moduledoc """
  Integration tests for AshStorage.Service.GoogleDrive against a real Google
  Workspace Shared Drive.

  Unlike the S3/AzureBlob integration tests, there is no way to Dockerize a
  real Shared Drive with a real service account, so these tests run against
  live Google infrastructure and are gated on environment variables rather
  than started automatically. They are the only thing that can actually
  exercise Shared Drive membership, Drive API enablement, and Goth scope
  configuration end to end — a mock server proves the request shapes are
  right, not that the real API accepts them.

  Required to run:

  - `GOOGLE_DRIVE_TEST_SHARED_DRIVE_ID` - the Shared Drive id to write to
  - `GOOGLE_DRIVE_TEST_SERVICE_ACCOUNT_JSON` - path to a service account
    credentials JSON file. The service account must be a member of the
    Shared Drive above (Content Manager or above), and the Drive API must be
    enabled in its Google Cloud project

  Tagged with :google_drive_integration so they're excluded from normal test
  runs. Skips (rather than fails) when the environment isn't configured.
  """
  use ExUnit.Case, async: false

  alias AshStorage.Service.Context
  alias AshStorage.Service.GoogleDrive

  @moduletag :google_drive_integration

  @goth_name AshStorage.Service.GoogleDriveIntegrationTest.Goth

  setup_all do
    case env_config() do
      {:ok, shared_drive_id, credentials_path} ->
        credentials = credentials_path |> File.read!() |> Jason.decode!()

        {:ok, _pid} =
          Goth.start_link(
            name: @goth_name,
            source:
              {:service_account, credentials, scopes: ["https://www.googleapis.com/auth/drive"]}
          )

        {:ok, shared_drive_id: shared_drive_id}

      :skip ->
        {:ok, skip: true}
    end
  end

  setup context do
    if context[:skip] do
      {:ok, skip: true}
    else
      ctx = Context.new(shared_drive_id: context.shared_drive_id, goth: @goth_name)
      {:ok, ctx: ctx}
    end
  end

  test "upload -> download -> head -> delete against a real Shared Drive", context do
    unless context[:skip] do
      %{ctx: ctx} = context
      key = "integration-test-#{System.unique_integer([:positive])}"
      content = "hello from the ash_storage integration suite"

      assert {:ok, %{service_opts: opts}} =
               GoogleDrive.upload(key, content, %{ctx | content_type: "text/plain"})

      ctx = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}

      assert {:ok, ^content} = GoogleDrive.download(key, ctx)
      assert {:ok, %{byte_size: size, content_md5: md5}} = GoogleDrive.head(key, ctx)
      assert size == byte_size(content)
      assert is_binary(md5)

      assert :ok = GoogleDrive.delete(key, ctx)
      assert {:ok, false} = GoogleDrive.exists?(key, ctx)
    end
  end

  test "a file created with no :folder_id lands under the Shared Drive root", context do
    unless context[:skip] do
      %{ctx: ctx, shared_drive_id: shared_drive_id} = context
      key = "integration-test-root-#{System.unique_integer([:positive])}"
      assert {:ok, %{service_opts: opts}} = GoogleDrive.upload(key, "root placement check", ctx)

      on_exit(fn ->
        ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}
        GoogleDrive.delete(key, ctx_with_id)
      end)

      # Hit the real API directly, independent of GoogleDrive's own code, to
      # prove the file actually landed where :folder_id's absence claims it
      # does -- a bug in the module under test shouldn't be able to make
      # this pass by construction.
      {:ok, %Goth.Token{token: token}} = Goth.fetch(@goth_name)

      assert {:ok, %Req.Response{status: 200, body: body}} =
               Req.get(
                 "https://www.googleapis.com/drive/v3/files/#{opts[:drive_file_id]}",
                 auth: {:bearer, token},
                 params: %{fields: "parents", supportsAllDrives: true}
               )

      assert body["parents"] == [shared_drive_id]
    end
  end

  defp env_config do
    with shared_drive_id when is_binary(shared_drive_id) <-
           System.get_env("GOOGLE_DRIVE_TEST_SHARED_DRIVE_ID"),
         path when is_binary(path) <-
           System.get_env("GOOGLE_DRIVE_TEST_SERVICE_ACCOUNT_JSON") do
      {:ok, shared_drive_id, path}
    else
      _ -> :skip
    end
  end
end
