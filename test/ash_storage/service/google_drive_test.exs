defmodule AshStorage.Service.GoogleDriveTest do
  use ExUnit.Case, async: false

  alias AshStorage.Operations
  alias AshStorage.Service.Context
  alias AshStorage.Service.GoogleDrive, as: Drive
  alias AshStorage.Test.ConfigurablePost

  @shared_drive_id "shared-drive-123"

  describe "handle_response/1" do
    test "a 2xx response is {:ok, body}" do
      assert {:ok, %{"id" => "abc"}} =
               Drive.handle_response({:ok, %Req.Response{status: 200, body: %{"id" => "abc"}}})

      assert {:ok, ""} = Drive.handle_response({:ok, %Req.Response{status: 204, body: ""}})
    end

    test "a 404 is :not_found" do
      assert {:error, :not_found} =
               Drive.handle_response({:ok, %Req.Response{status: 404, body: %{}}})
    end

    test "a 403 is a generic http error, logged" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:http_error, 403}} =
                   Drive.handle_response(
                     {:ok, %Req.Response{status: 403, body: %{"error" => "forbidden"}}}
                   )
        end)

      assert log =~ "403"
    end

    test "another status (e.g. 500) is a generic http error carrying the status" do
      assert {:error, {:http_error, 500}} =
               Drive.handle_response({:ok, %Req.Response{status: 500, body: "boom"}})
    end

    test "a transport-level error is passed through" do
      assert {:error, :timeout} = Drive.handle_response({:error, :timeout})
    end
  end

  describe "request builders carry supportsAllDrives: true" do
    test "every builder carries it" do
      requests = [
        Drive.build_create_session_request("key", "photo.jpg", "text/plain", 5,
          shared_drive_id: @shared_drive_id
        ),
        Drive.build_update_session_request("id-1", "text/plain", 5,
          shared_drive_id: @shared_drive_id
        ),
        Drive.build_lookup_request("key", shared_drive_id: @shared_drive_id),
        Drive.build_download_request("id-1", shared_drive_id: @shared_drive_id),
        Drive.build_metadata_request("id-1", shared_drive_id: @shared_drive_id),
        Drive.build_exists_request("id-1", shared_drive_id: @shared_drive_id),
        Drive.build_delete_request("id-1", shared_drive_id: @shared_drive_id)
      ]

      for request <- requests do
        assert request[:params][:supportsAllDrives] == true, "missing on #{inspect(request)}"
      end
    end

    test "the lookup request also carries includeItemsFromAllDrives: true" do
      request = Drive.build_lookup_request("key", shared_drive_id: @shared_drive_id)
      assert request[:params][:includeItemsFromAllDrives] == true
      assert request[:params][:corpora] == "drive"
      assert request[:params][:driveId] == @shared_drive_id
    end
  end

  describe "build_create_session_request/5" do
    test "targets the resumable upload endpoint with the metadata" do
      request =
        Drive.build_create_session_request("key-abc123", "notes.txt", "text/plain", 11,
          shared_drive_id: @shared_drive_id
        )

      assert request[:method] == :post
      assert request[:url] == "https://www.googleapis.com/upload/drive/v3/files"
      assert request[:params][:uploadType] == "resumable"

      assert request[:json] == %{
               name: "notes.txt",
               mimeType: "text/plain",
               parents: [@shared_drive_id],
               appProperties: %{"ash_storage_key" => "key-abc123"}
             }
    end

    test "a configured :folder_id is used as the parent instead of the Shared Drive id" do
      request =
        Drive.build_create_session_request("key-abc123", "notes.txt", "text/plain", 11,
          shared_drive_id: @shared_drive_id,
          folder_id: "folder-1"
        )

      assert request[:json][:parents] == ["folder-1"]
    end

    test "carries the size and content type as upload headers" do
      request =
        Drive.build_create_session_request("key-abc123", "notes.txt", "text/plain", 11,
          shared_drive_id: @shared_drive_id
        )

      headers = Map.new(request[:headers])
      assert headers["x-upload-content-type"] == "text/plain"
      assert headers["x-upload-content-length"] == "11"
    end

    test "stores the key under :appProperties by default" do
      request =
        Drive.build_create_session_request("key-abc123", "notes.txt", "text/plain", 11,
          shared_drive_id: @shared_drive_id
        )

      assert request[:json][:appProperties] == %{"ash_storage_key" => "key-abc123"}
      refute Map.has_key?(request[:json], :properties)
    end

    test "stores the key under :properties when :key_property is :properties" do
      request =
        Drive.build_create_session_request("key-abc123", "notes.txt", "text/plain", 11,
          shared_drive_id: @shared_drive_id,
          key_property: :properties
        )

      assert request[:json][:properties] == %{"ash_storage_key" => "key-abc123"}
      refute Map.has_key?(request[:json], :appProperties)
    end
  end

  describe "build_update_session_request/4" do
    test "targets the file by id and omits :parents, :name, and :appProperties" do
      request =
        Drive.build_update_session_request("id-1", "text/plain", 11,
          shared_drive_id: @shared_drive_id
        )

      assert request[:method] == :patch
      assert request[:url] == "https://www.googleapis.com/upload/drive/v3/files/id-1"
      assert request[:params][:uploadType] == "resumable"
      refute Map.has_key?(request[:json], :parents)
      refute Map.has_key?(request[:json], :name)
      refute Map.has_key?(request[:json], :appProperties)
    end
  end

  describe "build_download_request/2" do
    test "targets alt=media" do
      request = Drive.build_download_request("id-1", shared_drive_id: @shared_drive_id)

      assert request[:method] == :get
      assert request[:url] == "https://www.googleapis.com/drive/v3/files/id-1"
      assert request[:params][:alt] == "media"
    end
  end

  describe "build_metadata_request/2" do
    test "requests explicit fields including md5Checksum" do
      request = Drive.build_metadata_request("id-1", shared_drive_id: @shared_drive_id)

      assert request[:params][:fields] =~ "md5Checksum"
      assert request[:params][:fields] =~ "size"
    end
  end

  describe "service_opts_fields/0" do
    test "declares :goth (a reference) but never :access_token (a secret)" do
      keys = Keyword.keys(Drive.service_opts_fields())

      assert :shared_drive_id in keys
      assert :goth in keys
      assert :drive_file_id in keys
      refute :access_token in keys
    end

    test ":shared_drive_id is required" do
      fields = Drive.service_opts_fields()
      assert fields[:shared_drive_id][:allow_nil?] == false
    end
  end

  describe "persisted_opts/2" do
    test "rebuilds the whole map, not just the id" do
      opts = Drive.persisted_opts([shared_drive_id: @shared_drive_id, goth: MyApp.Goth], "id-1")

      assert opts[:shared_drive_id] == @shared_drive_id
      assert opts[:goth] == MyApp.Goth
      assert opts[:drive_file_id] == "id-1"
    end

    test "drops fields not in service_opts_fields/0" do
      opts =
        Drive.persisted_opts(
          [shared_drive_id: @shared_drive_id, access_token: "raw-token"],
          "id-1"
        )

      refute Map.has_key?(opts, :access_token)
    end
  end

  describe "url/2" do
    test "raises when neither :base_url nor a cached id is available" do
      ctx = Context.new(shared_drive_id: @shared_drive_id)
      assert_raise ArgumentError, ~r/no :base_url/, fn -> Drive.url("key", ctx) end
    end

    test "returns a base_url-relative URL when :base_url is configured" do
      ctx = Context.new(shared_drive_id: @shared_drive_id, base_url: "https://app.example/files")
      assert Drive.url("key-1", ctx) == "https://app.example/files/key-1"
    end

    test "falls back to a drive.google.com link when only a cached id is available" do
      ctx = Context.new(shared_drive_id: @shared_drive_id, drive_file_id: "id-1")
      assert Drive.url("key-1", ctx) == "https://drive.google.com/file/d/id-1/view"
    end

    test "signs the URL when :base_url and :secret are both set" do
      ctx =
        Context.new(
          shared_drive_id: @shared_drive_id,
          base_url: "https://app.example/files",
          secret: "a-long-secret-key-32-bytes-min!!"
        )

      url = Drive.url("key-1", ctx)
      assert url =~ "https://app.example/files/key-1?"
    end
  end

  describe "credential resolution" do
    test "an :access_token in service_opts is used directly, no Goth call" do
      ctx = Context.new(shared_drive_id: @shared_drive_id, access_token: "raw-token")
      # No mock server needed: build_lookup_request's `perform/2` would fail to
      # connect without one, so a network-free way to prove the token path
      # was taken is to check exists? errors with a connection failure (not
      # :missing_credentials or a Goth error).
      assert {:error, reason} = Drive.exists?("some-key", ctx)
      refute reason == :missing_credentials
      refute match?({:goth_unavailable, _}, reason)
    end

    test "neither :access_token nor :goth configured is :missing_credentials" do
      ctx = Context.new(shared_drive_id: @shared_drive_id)
      assert {:error, :missing_credentials} = Drive.exists?("some-key", ctx)
    end

    test "an unregistered :goth name fails as :goth_unavailable, not an exit" do
      ctx = Context.new(shared_drive_id: @shared_drive_id, goth: NoSuchGothServer)

      assert Process.whereis(NoSuchGothServer) == nil

      assert {:error, {:goth_unavailable, _}} = Drive.exists?("some-key", ctx)
    end
  end

  describe "escape_q (via build_lookup_request/2)" do
    test "escapes single quotes and backslashes in the key" do
      request = Drive.build_lookup_request(~s(weird'key\\here), shared_drive_id: @shared_drive_id)
      assert request[:params][:q] =~ ~s(weird\\'key\\\\here)
    end
  end

  describe "build_lookup_request/2 and :key_property" do
    test "queries appProperties by default" do
      request = Drive.build_lookup_request("key-1", shared_drive_id: @shared_drive_id)
      assert request[:params][:q] =~ "appProperties has { key='ash_storage_key'"
    end

    test "queries properties when :key_property is :properties" do
      request =
        Drive.build_lookup_request("key-1",
          shared_drive_id: @shared_drive_id,
          key_property: :properties
        )

      assert request[:params][:q] =~ "properties has { key='ash_storage_key'"
      refute request[:params][:q] =~ "appProperties"
    end
  end

  describe "service_opts_fields/0 and :key_property" do
    test "declares :key_property" do
      assert Keyword.has_key?(Drive.service_opts_fields(), :key_property)
    end
  end

  # -- Mock Google Drive server --
  #
  # A hand-rolled HTTP/1.1 server over :gen_tcp, following the same pattern
  # as AshStorage.Service.AzureBlobTest's mock: one request per connection,
  # Content-Length bodies only. It tracks Drive objects (id, name, parents,
  # bytes, mime type) and resumable-upload sessions in an Agent, and routes
  # on path + query params the way the real Drive API distinguishes
  # list/get/download/metadata calls that all hit `/files` or `/files/{id}`.

  describe "against a mock Drive API" do
    setup do
      {:ok, server_state} =
        Agent.start_link(fn -> %{objects: %{}, sessions: %{}, requests: [], next_id: 1} end)

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)
      acceptor = spawn(fn -> accept_loop(listener, server_state) end)

      on_exit(fn ->
        :gen_tcp.close(listener)
        Process.exit(acceptor, :shutdown)
        if Process.alive?(server_state), do: Agent.stop(server_state)
      end)

      base_url = "http://127.0.0.1:#{port}"

      ctx =
        Context.new(
          shared_drive_id: @shared_drive_id,
          access_token: "test-token",
          api_base_url: "#{base_url}/drive/v3",
          upload_base_url: "#{base_url}/upload/drive/v3"
        )

      {:ok, ctx: ctx, server_state: server_state}
    end

    test "full round trip: upload -> exists? -> download -> head -> delete -> exists?", %{
      ctx: ctx
    } do
      key = unique_key()
      content = "hello from the mock drive server"

      assert {:ok, %{service_opts: opts}} = Drive.upload(key, content, ctx)
      assert opts[:drive_file_id]

      ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}

      assert {:ok, true} = Drive.exists?(key, ctx_with_id)
      assert {:ok, ^content} = Drive.download(key, ctx_with_id)

      assert {:ok, %{content_md5: md5, byte_size: size, etag: nil}} = Drive.head(key, ctx_with_id)
      assert byte_size(content) == size
      assert Base.decode64!(md5) |> byte_size() == 16

      assert :ok = Drive.delete(key, ctx_with_id)
      assert {:ok, false} = Drive.exists?(key, ctx_with_id)
      assert {:error, :not_found} = Drive.download(key, ctx_with_id)
    end

    test "an oversized key fails fast, without making any request", %{
      ctx: ctx,
      server_state: server_state
    } do
      # 110 bytes -- one over the 109-byte limit left by the 15-byte
      # "ash_storage_key" property name inside Drive's 124-byte cap.
      oversized_key = String.duplicate("a", 110)

      assert {:error, {:key_too_long, 110, 109}} = Drive.upload(oversized_key, "data", ctx)
      assert recorded_requests(server_state) == []
    end

    test "a 109-byte key is accepted", %{ctx: ctx} do
      key = String.duplicate("a", 109)
      assert {:ok, _} = Drive.upload(key, "data", ctx)
    end

    test "key_property: :properties round-trips through upload -> exists? -> download", %{
      ctx: ctx,
      server_state: server_state
    } do
      props_ctx = %{ctx | service_opts: Keyword.put(ctx.service_opts, :key_property, :properties)}
      key = unique_key()

      assert {:ok, %{service_opts: opts}} = Drive.upload(key, "properties mode", props_ctx)
      id = opts[:drive_file_id]

      object = Agent.get(server_state, fn state -> Map.fetch!(state.objects, id) end)
      assert Map.get(object.app_properties, "ash_storage_key") == key

      ctx_with_id = %{
        props_ctx
        | service_opts: Keyword.merge(props_ctx.service_opts, Map.to_list(opts))
      }

      assert {:ok, true} = Drive.exists?(key, ctx_with_id)
      assert {:ok, "properties mode"} = Drive.download(key, ctx_with_id)

      # And a lookup with no cached id, still in :properties mode, resolves too.
      assert {:ok, true} = Drive.exists?(key, props_ctx)
    end

    test "the Drive file's display name is the human filename, not the opaque key", %{
      ctx: ctx,
      server_state: server_state
    } do
      key = unique_key()
      named_ctx = %{ctx | filename: "vacation-photo.jpg"}

      assert {:ok, %{service_opts: opts}} = Drive.upload(key, "photo bytes", named_ctx)
      id = opts[:drive_file_id]

      object = Agent.get(server_state, fn state -> Map.fetch!(state.objects, id) end)
      assert object.name == "vacation-photo.jpg"
      assert Map.get(object.app_properties, "ash_storage_key") == key

      # The key, not the display name, is still what resolves the id -- a
      # human renaming the file in the Drive UI (simulated here) must not
      # break lookup.
      Agent.update(server_state, fn state ->
        put_in(state, [:objects, id, :name], "renamed-by-a-human.jpg")
      end)

      ctx_without_id = ctx
      assert {:ok, true} = Drive.exists?(key, ctx_without_id)
    end

    test "upload/3 falls back to the key as the display name when ctx.filename is unset", %{
      ctx: ctx,
      server_state: server_state
    } do
      key = unique_key()
      assert {:ok, %{service_opts: opts}} = Drive.upload(key, "no filename given", ctx)

      object =
        Agent.get(server_state, fn state -> Map.fetch!(state.objects, opts[:drive_file_id]) end)

      assert object.name == key
    end

    test "the session-start POST carries only JSON metadata; the PUT to the session URL carries the file bytes",
         %{ctx: ctx, server_state: server_state} do
      key = unique_key()
      assert {:ok, _} = Drive.upload(key, "the bytes", ctx)

      requests = recorded_requests(server_state)
      post = Enum.find(requests, &(&1.method == "POST" and String.contains?(&1.path, "/files")))
      put = Enum.find(requests, &(&1.method == "PUT" and String.contains?(&1.path, "/session/")))

      assert post
      assert put
      assert Jason.decode!(post.body)["name"] == key
      refute post.body =~ "the bytes"
      assert put.body == "the bytes"
    end

    test "a session POST with no Location header surfaces as :missing_upload_session_url", %{
      ctx: ctx,
      server_state: server_state
    } do
      Agent.update(server_state, fn state -> Map.put(state, :suppress_location, true) end)

      assert {:error, :missing_upload_session_url} = Drive.upload(unique_key(), "data", ctx)
    end

    test "upload verifies against Drive's own reported md5Checksum", %{ctx: ctx} do
      matching_ctx = %{ctx | expected_md5: Base.encode64(:erlang.md5("the real bytes"))}
      assert {:ok, _} = Drive.upload(unique_key(), "the real bytes", matching_ctx)

      mismatched_ctx = %{
        ctx
        | expected_md5: Base.encode64(:erlang.md5("something else entirely"))
      }

      assert {:error, :checksum_mismatch} =
               Drive.upload(unique_key(), "the real bytes", mismatched_ctx)
    end

    test "uploading a %File.Stream{} delivers identical bytes to uploading the equivalent binary",
         %{ctx: ctx} do
      content = :crypto.strong_rand_bytes(5_000)

      path =
        Path.join(System.tmp_dir!(), "google-drive-upload-#{System.unique_integer([:positive])}")

      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      key = unique_key()
      assert {:ok, %{service_opts: opts}} = Drive.upload(key, File.stream!(path, 1024), ctx)

      ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}
      assert {:ok, ^content} = Drive.download(key, ctx_with_id)
    end

    test "re-uploading to the same key updates rather than duplicates", %{
      ctx: ctx,
      server_state: server_state
    } do
      key = unique_key()
      assert {:ok, %{service_opts: opts1}} = Drive.upload(key, "version one", ctx)
      assert {:ok, %{service_opts: opts2}} = Drive.upload(key, "version two", ctx)

      assert opts1[:drive_file_id] == opts2[:drive_file_id]

      requests = recorded_requests(server_state)

      assert Enum.count(
               requests,
               &(&1.method == "PATCH" and String.contains?(&1.path, "/files/"))
             ) == 1

      ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts2))}
      assert {:ok, "version two"} = Drive.download(key, ctx_with_id)

      # Only one object should exist under this key, not two.
      lookup_ctx = ctx
      assert {:ok, true} = Drive.exists?(key, lookup_ctx)
    end

    test "download does not decode a stored JSON body unless :decode_body is set", %{ctx: ctx} do
      key = unique_key()
      json = ~s({"a":1})

      assert {:ok, %{service_opts: opts}} =
               Drive.upload(key, json, %{ctx | content_type: "application/json"})

      raw_ctx = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}
      assert {:ok, ^json} = Drive.download(key, raw_ctx)

      decoding_ctx = %{
        raw_ctx
        | service_opts: Keyword.put(raw_ctx.service_opts, :decode_body, true)
      }

      assert {:ok, %{"a" => 1}} = Drive.download(key, decoding_ctx)
    end

    test "head/2 returns content_md5: nil for an object with no md5Checksum", %{
      ctx: ctx,
      server_state: server_state
    } do
      key = unique_key()
      assert {:ok, %{service_opts: opts}} = Drive.upload(key, "native doc body", ctx)
      id = opts[:drive_file_id]

      Agent.update(server_state, fn state ->
        put_in(state, [:objects, id, :md5], nil)
      end)

      ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}
      assert {:ok, %{content_md5: nil}} = Drive.head(key, ctx_with_id)
    end

    test "delete is :ok for a key that was never uploaded", %{ctx: ctx} do
      assert :ok = Drive.delete(unique_key(), ctx)
    end

    test "two files sharing a name is :ambiguous_key, never picked arbitrarily", %{
      ctx: ctx,
      server_state: server_state
    } do
      key = unique_key()
      assert {:ok, _} = Drive.upload(key, "one", ctx)

      # Force a duplicate directly into the mock store, bypassing upload/3's
      # own update-on-reupload behavior, to simulate the race this design
      # guards against.
      Agent.update(server_state, fn state ->
        {id, obj} =
          Enum.find(state.objects, fn {_id, o} ->
            Map.get(o.app_properties, "ash_storage_key") == key
          end)

        duplicate_id = "dup-#{id}"
        %{state | objects: Map.put(state.objects, duplicate_id, obj)}
      end)

      assert {:error, {:ambiguous_key, ^key, ids}} = Drive.exists?(key, ctx)
      assert length(ids) == 2
    end

    test ":folder_id actually scopes the lookup, not just the create request", %{ctx: ctx} do
      folder_ctx = %{ctx | service_opts: Keyword.put(ctx.service_opts, :folder_id, "folder-1")}
      key = unique_key()

      assert {:ok, _} = Drive.upload(key, "in a folder", folder_ctx)

      # A lookup scoped to the Shared Drive root (no :folder_id) must not
      # find a file that was created under a different parent.
      assert {:ok, false} = Drive.exists?(key, ctx)
      assert {:ok, true} = Drive.exists?(key, folder_ctx)
    end

    test "a file trashed on Drive reports as not existing", %{
      ctx: ctx,
      server_state: server_state
    } do
      key = unique_key()
      assert {:ok, %{service_opts: opts}} = Drive.upload(key, "will be trashed", ctx)
      id = opts[:drive_file_id]

      Agent.update(server_state, fn state ->
        put_in(state, [:objects, id, :trashed], true)
      end)

      ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}
      assert {:ok, false} = Drive.exists?(key, ctx_with_id)
    end

    test "chunks concatenate to exactly what download/2 returns", %{ctx: ctx} do
      key = unique_key()
      content = :crypto.strong_rand_bytes(200_000)
      assert {:ok, %{service_opts: opts}} = Drive.upload(key, content, ctx)

      ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}

      assert {:ok, async} = Drive.stream_download(key, ctx_with_id)
      assert async |> Enum.to_list() |> IO.iodata_to_binary() == content
    end

    test "an empty object yields chunks concatenating to an empty binary", %{ctx: ctx} do
      key = unique_key()
      assert {:ok, %{service_opts: opts}} = Drive.upload(key, "", ctx)

      ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}

      assert {:ok, async} = Drive.stream_download(key, ctx_with_id)
      assert async |> Enum.to_list() |> IO.iodata_to_binary() == ""
    end

    test "a 404 returns :not_found and leaves no stray messages in the caller's mailbox", %{
      ctx: ctx
    } do
      ctx_missing_id = %{
        ctx
        | service_opts: Keyword.put(ctx.service_opts, :drive_file_id, "missing-id")
      }

      assert {:error, :not_found} = Drive.stream_download(unique_key(), ctx_missing_id)
      refute_receive _, 50
    end

    test "consuming the enumerable outside the calling process raises", %{ctx: ctx} do
      key = unique_key()
      assert {:ok, %{service_opts: opts}} = Drive.upload(key, "abc", ctx)
      ctx_with_id = %{ctx | service_opts: Keyword.merge(ctx.service_opts, Map.to_list(opts))}

      assert {:ok, async} = Drive.stream_download(key, ctx_with_id)

      # Task.async/1 links the task to this process, so a crashing task would
      # also crash (and fail) the test via that link before assert_raise ever
      # got a chance to catch anything. spawn_monitor has no link, so the
      # raise is observable purely as a :DOWN message here.
      {pid, ref} = spawn_monitor(fn -> Enum.to_list(async) end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{message: message}, _stacktrace}}
      assert message =~ "expected to read body chunk"
    end

    setup %{ctx: ctx} do
      # access_token is intentionally included here to prove it never
      # reaches the persisted row -- only :shared_drive_id, :goth, and the
      # cached :drive_file_id should survive.
      opts = Keyword.put(ctx.service_opts, :goth, NoSuchGothServer)

      Application.put_env(:ash_storage, ConfigurablePost,
        storage: [service: {AshStorage.Service.GoogleDrive, opts}]
      )

      on_exit(fn -> Application.delete_env(:ash_storage, ConfigurablePost) end)

      :ok
    end

    test "the blob row persists :drive_file_id, :shared_drive_id and :goth, never :access_token" do
      post =
        ConfigurablePost
        |> Ash.Changeset.for_create(:create, %{title: "p"})
        |> Ash.create!()

      assert {:ok, %{blob: blob}} =
               Operations.attach(post, :avatar, "hello drive",
                 filename: "f.txt",
                 content_type: "text/plain"
               )

      row_opts = Map.new(blob.service_opts || %{}, fn {k, v} -> {to_string(k), v} end)

      assert row_opts["shared_drive_id"] == @shared_drive_id
      assert is_binary(row_opts["drive_file_id"])
      # ConfigurablePost's blob resource is ETS-backed, so service_opts
      # round-trips as native Elixir terms (the atom survives as-is); a
      # jsonb-backed resource (Postgres) would store it as the string
      # "Elixir.NoSuchGothServer" instead -- resolve_goth_name/1 handles
      # both, see the `parsed_service_opts` assertion below for the form
      # that matters (what a service call actually reads back).
      assert row_opts["goth"] == NoSuchGothServer
      refute Map.has_key?(row_opts, "access_token")

      # :goth round-trips as an atom through the persisted-then-reloaded
      # path, not just on the freshly-created struct.
      assert {:ok, reloaded} = Ash.load(blob, :parsed_service_opts)
      assert reloaded.parsed_service_opts[:goth] == NoSuchGothServer

      # The dropped :access_token has a real, correctly-failing consequence:
      # a later call rebuilding its context purely from this row (download,
      # purge, analysis) has no live credential -- :goth survived, but names
      # a server that was never started, so it fails cleanly rather than
      # succeeding on a token that was never supposed to persist.
      assert {:error, {:goth_unavailable, _}} = Operations.download(blob)
    end
  end

  defp unique_key, do: "google-drive-key-#{System.unique_integer([:positive])}"

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
        handle_mock_request(socket, request, server_state)

      {:error, _reason} ->
        send_response(socket, 400, "", [])
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

  defp record_request(server_state, request) do
    Agent.update(server_state, fn state -> %{state | requests: [request | state.requests]} end)
  end

  defp recorded_requests(server_state) do
    Agent.get(server_state, fn state -> Enum.reverse(state.requests) end)
  end

  # -- Mock routing --

  defp handle_mock_request(socket, request, server_state) do
    record_request(server_state, request)
    {status, body, headers} = route(request, server_state)
    send_response(socket, status, body, headers)
  end

  # Resumable session start: create (POST /files) or update (PATCH /files/{id}).
  defp route(
         %{method: "POST", path: "/upload/drive/v3/files", query: %{"uploadType" => "resumable"}} =
           request,
         server_state
       ) do
    metadata = Jason.decode!(request.body)
    start_session(server_state, nil, metadata, request)
  end

  defp route(
         %{method: "PATCH", query: %{"uploadType" => "resumable"}} = request,
         server_state
       ) do
    case id_from_path(request.path, "/upload/drive/v3/files/") do
      {:ok, id} ->
        metadata = Jason.decode!(request.body)
        start_session(server_state, id, metadata, request)

      :error ->
        {404, "", []}
    end
  end

  # The PUT of bytes to a session URL.
  defp route(%{method: "PUT"} = request, server_state) do
    case id_from_path(request.path, "/session/") do
      {:ok, token} -> put_session_bytes(server_state, token, request)
      :error -> {404, "", []}
    end
  end

  # files.list
  defp route(%{method: "GET", path: "/drive/v3/files"} = request, server_state) do
    list_files(server_state, request.query)
  end

  # files.get, either alt=media (download), or fields=... (metadata / exists check)
  defp route(%{method: "GET"} = request, server_state) do
    case id_from_path(request.path, "/drive/v3/files/") do
      {:ok, id} -> get_file(server_state, id, request.query)
      :error -> {404, "", []}
    end
  end

  defp route(%{method: "DELETE"} = request, server_state) do
    case id_from_path(request.path, "/drive/v3/files/") do
      {:ok, id} -> delete_file(server_state, id)
      :error -> {404, "", []}
    end
  end

  defp route(_request, _server_state), do: {405, "", []}

  defp id_from_path(path, prefix) do
    if String.starts_with?(path, prefix) do
      {:ok, String.replace_prefix(path, prefix, "")}
    else
      :error
    end
  end

  defp start_session(server_state, existing_id, metadata, request) do
    suppress? = Agent.get(server_state, &Map.get(&1, :suppress_location, false))
    token = "sess-#{System.unique_integer([:positive])}"

    Agent.update(server_state, fn state ->
      %{state | sessions: Map.put(state.sessions, token, %{id: existing_id, metadata: metadata})}
    end)

    if suppress? do
      {200, "", []}
    else
      host = Map.fetch!(request.headers, "host")
      {200, "", [{"location", "http://#{host}/session/#{token}"}]}
    end
  end

  defp put_session_bytes(server_state, token, request) do
    case Agent.get(server_state, fn state -> Map.get(state.sessions, token) end) do
      nil ->
        {404, "", []}

      %{id: existing_id, metadata: metadata} ->
        body = request.body
        mime = Map.get(metadata, "mimeType")
        md5 = Base.encode16(:erlang.md5(body), case: :lower)

        id =
          Agent.get_and_update(server_state, fn state ->
            case existing_id do
              nil ->
                id = "id-#{state.next_id}"

                object = %{
                  name: Map.fetch!(metadata, "name"),
                  parents: Map.fetch!(metadata, "parents"),
                  app_properties:
                    Map.get(metadata, "appProperties") || Map.get(metadata, "properties") || %{},
                  mime_type: mime,
                  body: body,
                  md5: md5,
                  trashed: false
                }

                {id,
                 %{
                   state
                   | objects: Map.put(state.objects, id, object),
                     next_id: state.next_id + 1
                 }}

              id ->
                object =
                  state.objects
                  |> Map.fetch!(id)
                  |> Map.merge(%{mime_type: mime, body: body, md5: md5})

                {id, %{state | objects: Map.put(state.objects, id, object)}}
            end
          end)

        response =
          Jason.encode!(%{
            "id" => id,
            "size" => Integer.to_string(byte_size(body)),
            "mimeType" => mime,
            "md5Checksum" => md5
          })

        {200, response, [{"content-type", "application/json"}]}
    end
  end

  defp list_files(server_state, query) do
    q = query["q"] || ""
    key = extract_q_app_property(q, "ash_storage_key")
    parent = extract_q_field(q, "parent")

    files =
      Agent.get(server_state, fn state ->
        state.objects
        |> Enum.filter(fn {_id, object} ->
          Map.get(object.app_properties, "ash_storage_key") == key and not object.trashed and
            (is_nil(parent) or parent in object.parents)
        end)
        |> Enum.map(fn {id, object} ->
          %{
            "id" => id,
            "name" => object.name,
            "size" => Integer.to_string(byte_size(object.body)),
            "mimeType" => object.mime_type,
            "md5Checksum" => object.md5
          }
        end)
      end)

    {200, Jason.encode!(%{"files" => files}), [{"content-type", "application/json"}]}
  end

  defp extract_q_app_property(q, property_key) do
    pattern =
      ~r/(?:appProperties|properties) has \{ key='#{Regex.escape(property_key)}' and value='((?:[^'\\]|\\.)*)' \}/

    case Regex.run(pattern, q) do
      [_, value] -> unescape_q(value)
      _ -> nil
    end
  end

  defp extract_q_field(q, "parent") do
    case Regex.run(~r/'((?:[^'\\]|\\.)*)' in parents/, q) do
      [_, value] -> unescape_q(value)
      _ -> nil
    end
  end

  defp unescape_q(value), do: value |> String.replace("\\'", "'") |> String.replace("\\\\", "\\")

  defp get_file(server_state, id, query) do
    case Agent.get(server_state, fn state -> Map.fetch(state.objects, id) end) do
      {:ok, %{trashed: true}} ->
        {404, "", []}

      {:ok, object} ->
        cond do
          query["alt"] == "media" ->
            {200, object.body, [{"content-type", object.mime_type || "application/octet-stream"}]}

          Map.has_key?(query, "fields") and String.contains?(query["fields"], "trashed") ->
            {200, Jason.encode!(%{"id" => id, "trashed" => object.trashed}),
             [{"content-type", "application/json"}]}

          true ->
            body = %{
              "id" => id,
              "name" => object.name,
              "size" => Integer.to_string(byte_size(object.body)),
              "mimeType" => object.mime_type,
              "md5Checksum" => object.md5
            }

            {200, Jason.encode!(body), [{"content-type", "application/json"}]}
        end

      :error ->
        {404, "", []}
    end
  end

  defp delete_file(server_state, id) do
    existed? =
      Agent.get_and_update(server_state, fn state ->
        {Map.has_key?(state.objects, id), %{state | objects: Map.delete(state.objects, id)}}
      end)

    if existed?, do: {204, "", []}, else: {404, "", []}
  end

  defp send_response(socket, status, body, extra_headers) do
    extra = Enum.map(extra_headers, fn {k, v} -> "#{k}: #{v}\r\n" end)

    response = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason_phrase(status),
      "\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      extra,
      "connection: close\r\n\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(204), do: "No Content"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"
end
