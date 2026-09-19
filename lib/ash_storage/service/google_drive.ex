if Code.ensure_loaded?(Req) do
  defmodule AshStorage.Service.GoogleDrive do
    @moduledoc """
    A storage service for Google Drive, writing to a Google Workspace Shared
    Drive through a service account.

    Ported from a production Google Drive client, not written from the Drive
    API reference — the rules below are the ones that cost real debugging
    time there, and every one of them fails quietly rather than loudly.

    ## Configuration

        storage do
          service {AshStorage.Service.GoogleDrive,
            shared_drive_id: "0AB...",
            goth: MyApp.Goth}
        end

    ## Options

    - `:shared_drive_id` - (required) the id of the Shared Drive to store files on
    - `:base_url` - (required in practice for `url/2`) proxy this points at,
      e.g. your own `AshStorage.Plug.Proxy` route. The built-in URL
      calculations (`url`, `attachment_url`, `attachment_urls`, `variant_url`,
      `variant_urls`) all build their context from resource-level
      configuration, which never carries a cached `:drive_file_id` — so
      without `:base_url`, `url/2` raises on every one of them. See
      "URLs are not access control" below
    - `:secret` - secret key for signed URLs under `:base_url`, as
      `AshStorage.Service.Disk` does it
    - `:folder_id` - a Drive folder id to create files under. Defaults to the
      Shared Drive's root
    - `:key_property` - `:app_properties` (default) or `:properties`. Where
      the AshStorage key is stored on the Drive file — both are invisible in
      the Drive UI; see "Keys, names, and Drive ids" below for the tradeoff
    - `:goth` - the name of an already-running `Goth` server to fetch bearer
      tokens from. Persisted on blob records (it is a reference, not a
      secret) so operations that start from a stored row — purge, analysis,
      variants — resolve credentials the same way a request-time call does
    - `:access_token` - a raw bearer token, honored for the call it's passed
      on. Not persisted on blob records; use `:goth` for purge/analysis/variants
    - `:drive_file_id` - the Drive-assigned id for this object. Populated
      automatically on `upload/3` and persisted on the blob record as a
      cache; not meant to be set by hand
    - `:decode_body` - opt back into Req's content-type response decoding on
      `download/2`. Defaults to `false`; see the `AshStorage.Service`
      `download/2` callback docs for the raw-bytes contract
    - `:api_base_url` - override for the Drive API base URL (default:
      `"https://www.googleapis.com/drive/v3"`). Used by tests against a mock
      server
    - `:upload_base_url` - override for the Drive upload API base URL
      (default: `"https://www.googleapis.com/upload/drive/v3"`)

    ## Shared Drive setup

    1. **`supportsAllDrives: true` on every call, no exceptions.** Omit it
       and the API does not error — it behaves as though Shared Drive items
       do not exist. Calls return 200 with nothing in them. Every request
       this module builds carries it. Listing calls additionally carry
       `includeItemsFromAllDrives: true`.
    2. **A service account has no storage quota of its own.** It cannot own
       files in "My Drive." Uploads fail with a quota error or land
       nowhere. You must use a Workspace Shared Drive with the service
       account added as a member at Content Manager or above. **This
       presents as a broken-credentials bug, not a missing-container bug**
       — if uploads fail and the token looks fine, check Shared Drive
       membership before you touch the credentials.
    3. **"No parent" is not a thing on a Shared Drive.** A file with no
       folder parent still needs `parents: [shared_drive_id]`. Omitting
       `parents` targets the service account's nonexistent My Drive — see #2.
    4. **The Drive API must be separately enabled** in the Google Cloud
       console. A valid token with the right scope still 403s until it is.
       Reads exactly like a code-level permissions bug; it is not one.
    5. **OAuth scopes are fixed when the Goth server starts**, at
       `start_link` time, not per request. This service takes a Goth server
       name rather than starting its own, so the caller's Goth source must
       already include `"https://www.googleapis.com/auth/drive"`. Adding it
       here would do nothing.
    6. **Goth registers through its own registry, not as a named process.**
       `Process.whereis(MyApp.Goth)` returns `nil` while Goth is running
       fine. Never probe the process name; this module calls `Goth.fetch/1`
       and handles its error.
    7. **Drive returns sparse objects unless you ask for `fields`.** `head/2`
       and the id lookup used internally both request explicit `fields`;
       without them the response is essentially empty.
    8. **Moving a file is not one PATCH.** Shared Drive items have exactly
       one parent, so a move must GET the current `parents` and PATCH
       `addParents` + `removeParents` together. This service is a flat
       key/value store and does not move files, but re-uploading to an
       existing key follows the same rule: the update request must not
       resend `parents`.

    ## Keys, names, and Drive ids

    `AshStorage` generates the `key` before calling any service — Drive
    assigns file ids server-side, so the two can't be the same value. This
    service does **not** put the key in the Drive file's `name`: a Shared
    Drive is often chosen specifically so a person can browse it directly if
    the app is unavailable, and a pile of opaque generated keys defeats that.
    Instead, `upload/3` sets `name` to the human filename from `ctx.filename`
    (falling back to the key only when no filename is known — currently true
    of variant uploads; `AshStorage.VariantGenerator` doesn't set `:filename`
    on the context it builds, unlike `attach/4` and `handle_file_argument.ex`,
    a pre-existing framework gap upstream of this service) and stores the key in
    `appProperties["ash_storage_key"]`, custom metadata invisible in the
    Drive UI. The Drive id is resolved by looking up that property
    (`files.list` filtered by an exact `appProperties has {...}` match, plus
    parent) when it isn't already known — an exact match on custom metadata,
    not the fuzzier territory of matching against a display name Drive may
    normalize or a user may rename by hand.

    Two things worth knowing about this choice:

    - **Where the key lives is a visibility/recoverability tradeoff, and
      it's configurable via `:key_property`.** The default,
      `:app_properties`, is private to the requesting app — readable only
      through an access token from the same OAuth client / service account
      that wrote it. Rotating to a new Google Cloud project or service
      account makes every existing file's key invisible to the new
      credentials: lookups return "not found," re-uploading to an old key
      creates a duplicate instead of updating, and every subsequent lookup
      for that key permanently returns `{:error, {:ambiguous_key, _, _}}` —
      silent and compounding, not a loud failure you'd notice right away.
      Set `key_property: :properties` instead to trade that away: still
      invisible in the Drive UI (Drive doesn't render custom properties of
      either kind), but readable by any authenticated caller with access to
      the file — recoverable if your credentials ever change, at the cost of
      the key being incidentally visible to anything else with file access
      (which, holding a Shared Drive access grant, could already read the
      file's actual contents — the key was never the sensitive part).
      `:app_properties` is the default because it matches the common case
      ("nothing outside this app should read this"); an application storing
      years of files under credentials that might someday need to rotate
      should weigh that against the recoverability `:properties` buys.
    - **Drive caps a property at 124 bytes of key + value, UTF-8-encoded.**
      With `"ash_storage_key"` (15 bytes) as the property key, that leaves
      109 bytes for the AshStorage key value itself, regardless of which
      `:key_property` you choose. The default generated key (56 hex chars)
      and the default tenant-prefixed form both fit with room to spare, but
      a custom `path` function (`AshStorage.resolve_key/3`) can return
      anything — `upload/3` checks the length itself and returns
      `{:error, {:key_too_long, byte_size, 109}}` before making any request
      if it's over, rather than surfacing whatever error Drive would return
      for an oversized property.

    `upload/3` caches the resolved id in `:drive_file_id` on the blob
    record, so most calls that start from a blob (`download/2`,
    `stream_download/2`) skip the lookup. Calls that build their context
    from resource-level configuration rather than a blob record — `purge`,
    `AttachBlob`, the `url/2` calculations, `AshStorage.Plug.Proxy` — always
    resolve by lookup, since no per-blob id is available there.

    Re-uploading to an existing key **updates** that file rather than
    creating a duplicate (an extra lookup, to match every other bundled
    service's overwrite-by-key behavior) — the update does not touch `name`
    or `appProperties` (omitting a field from a Drive update leaves it
    unchanged, it does not clear it), only the content, so a file a human
    has since renamed in the Drive UI stays renamed. More than one file
    sharing a key is treated as an error —
    `{:error, {:ambiguous_key, key, ids}}` — rather than picked from
    arbitrarily.

    Drive's `files.list` search is index-backed and only eventually
    consistent — a lookup immediately after a create can occasionally miss,
    which `upload/3` would read as "no existing file" and take the create
    branch, permanently poisoning that key with an `:ambiguous_key` error
    once the index catches up and a second file with the same property
    exists. This is inherent to searching Drive by metadata rather than
    addressing by id, and isn't specific to using `appProperties` over
    `name` — an `:drive_file_id` cached on the blob record avoids it for
    that record going forward.

    ## URLs are not access control

    `url/2` is a required callback, but a Drive file's real URL is not
    something a browser can safely be handed: without an access-controlled
    proxy in front of it, whoever holds the link gets a Google sign-in page
    for a file they may or may not be allowed to see, and the link leaks the
    Drive file id.

    - When `:base_url` is set in `service_opts`, `url/2` returns a URL under
      it instead (optionally HMAC-signed when `:secret` is also set, exactly
      as `AshStorage.Service.Disk` does) — point this at your own
      `AshStorage.Plug.Proxy` or controller, so your application's policy
      decides who gets the bytes. **This is the only configuration the
      built-in URL calculations work with.**
    - Without `:base_url`, `url/2` never makes a network call to find
      something to link to (a per-record Drive lookup from a list query
      would be an accidental N+1) — it only ever returns
      `https://drive.google.com/file/d/\#{id}/view` when the context you
      built already carries a `:drive_file_id`, which only happens for a
      context assembled from a blob record by hand. The built-in URL
      calculations (`url`, `attachment_url`, `attachment_urls`, `variant_url`,
      `variant_urls`) build their context from resource-level configuration,
      never a blob record, so this fallback is unreachable from any of
      them — they raise `ArgumentError` instead, same as with no `:base_url`
      and no id at all. **This is not an access-controlled URL** even when
      it is reachable — do not put it in front of end users.

    ## Limits

    - `direct_upload/2` always returns `{:error, :direct_upload_not_supported}`.
      Drive has no clean client-side signed-upload scheme for a
      service-account-backed adapter without delegating OAuth to the
      browser, and there is no way to persist a Drive id discovered after
      the fact (`AshStorage.Operations.prepare_direct_upload/3` creates the
      blob record before calling the service, and its return value is never
      merged back onto the row — a pre-existing gap in `Operations` that
      also means the blob record from a failed `prepare_direct_upload/3`
      call is not automatically cleaned up). Upload through `attach/4`, or
      call `upload/3` directly.
    - `stream_download/2` returns a `Req.Response.Async`. It must be
      consumed in the same process that called `stream_download/2` — unlike
      `AshStorage.Service.Disk`'s `File.Stream`, it cannot be handed to
      another process.
    - No folder mirroring. `:folder_id` lets every object for an attachment
      land under one existing folder; anything beyond that (per-record
      subfolders, renaming, moving) is out of scope for a flat key/value
      backend — Drive folder structure is a convenience for humans browsing
      the Shared Drive, not something this service manages.
    - Resumable uploads are single-shot: a failure partway through is not
      resumed from where it left off, it's retried from the start of
      `upload/3`.
    """

    @behaviour AshStorage.Service

    require Logger

    alias AshStorage.Service.Context

    @default_api_base_url "https://www.googleapis.com/drive/v3"
    @default_upload_base_url "https://www.googleapis.com/upload/drive/v3"

    # The custom-metadata key the AshStorage key is stored under (within
    # whichever of appProperties/properties :key_property selects). Not the
    # file's display name -- see build_create_session_request/5.
    @key_property "ash_storage_key"

    # Drive caps a custom property at 124 bytes of key + value combined,
    # UTF-8-encoded (see the "Keys, names, and Drive ids" moduledoc section).
    @max_key_bytes 124 - byte_size(@key_property)

    @impl true
    def service_opts_fields do
      [
        shared_drive_id: [type: :string, allow_nil?: false],
        folder_id: [type: :string],
        key_property: [type: :atom],
        goth: [type: :atom],
        drive_file_id: [type: :string],
        api_base_url: [type: :string],
        upload_base_url: [type: :string],
        decode_body: [type: :boolean]
      ]
    end

    @impl true
    def upload(key, io, %Context{} = ctx) do
      {body, size} = body_and_length(io)
      mime = ctx.content_type || "application/octet-stream"
      # Falls back to the key when no human filename is known (currently
      # true of variant uploads -- AshStorage.VariantGenerator doesn't set
      # :filename on the context it builds, unlike attach/4 and
      # handle_file_argument.ex). An opaque name there is a pre-existing
      # framework gap, not something to paper over silently here -- fixed
      # separately, not as part of this PR.
      name = ctx.filename || key

      with :ok <- validate_key_length(key),
           {:ok, token} <- resolve_token(ctx.service_opts),
           {:ok, existing_id} <- lookup_id(key, token, ctx.service_opts),
           {:ok, session_url} <-
             start_resumable_session(token, key, name, mime, size, existing_id, ctx.service_opts),
           {:ok, body_map} <-
             token |> put_bytes(session_url, body, size, mime) |> decoded_map(),
           # Drive has no upload-time Content-MD5 equivalent, but the
           # completion response is a file resource -- the `fields` param on
           # the initiate request carries through the session URL to it, so
           # this is verified for free once the bytes are already up.
           :ok <-
             verify_remote_md5(
               hex_to_base64_md5(Map.get(body_map, "md5Checksum")),
               ctx.expected_md5
             ) do
        {:ok, %{service_opts: persisted_opts(ctx.service_opts, Map.fetch!(body_map, "id"))}}
      end
    end

    # Rebuilds the whole persisted map (not just the id) -- attach.ex merges
    # `extra_blob_attrs` over the generically-computed `service_opts`
    # wholesale, so returning a partial map here would wipe :shared_drive_id
    # and :goth off the row. Public (but undocumented) so the round-trip can
    # be exercised directly in tests.
    @doc false
    def persisted_opts(service_opts, drive_file_id) do
      service_opts
      |> Keyword.take(Keyword.keys(service_opts_fields()))
      |> Keyword.put(:drive_file_id, drive_file_id)
      |> Map.new()
    end

    # Fails before making any request rather than letting Drive reject the
    # property with whatever error it returns for an oversized one.
    defp validate_key_length(key) do
      size = byte_size(key)

      if size <= @max_key_bytes do
        :ok
      else
        {:error, {:key_too_long, size, @max_key_bytes}}
      end
    end

    # :app_properties (default) keeps the key invisible in the Drive UI but
    # readable only by the app/credentials that wrote it -- rotating
    # projects or service accounts makes existing keys unresolvable.
    # :properties is equally invisible in the UI but readable by any
    # authenticated caller with access to the file, trading that visibility
    # for recoverability. See the "Keys, names, and Drive ids" moduledoc
    # section.
    defp key_property_atom(opts) do
      case Keyword.get(opts, :key_property, :app_properties) do
        :app_properties -> :appProperties
        :properties -> :properties
      end
    end

    defp key_property_query_name(opts), do: key_property_atom(opts) |> Atom.to_string()

    @impl true
    def download(key, %Context{} = ctx) do
      decode_body? = Keyword.get(ctx.service_opts, :decode_body, false)

      with {:ok, token} <- resolve_token(ctx.service_opts),
           {:ok, id} <- require_id(key, token, ctx.service_opts),
           {:ok, body} <-
             id
             |> build_download_request(ctx.service_opts)
             |> Keyword.merge(decode_body: decode_body?)
             |> perform(token)
             |> handle_response(),
           :ok <- verify_md5(body, ctx.expected_md5) do
        {:ok, body}
      end
    end

    @impl true
    def stream_download(key, %Context{} = ctx) do
      with {:ok, token} <- resolve_token(ctx.service_opts),
           {:ok, id} <- require_id(key, token, ctx.service_opts) do
        request =
          id
          |> build_download_request(ctx.service_opts)
          # retry: false -- Req's retry step doesn't cancel an in-flight
          # Async response before re-running the request (unlike its
          # redirect step, which does), so a retried streaming request would
          # leave the first attempt's chunks sitting in this process's
          # mailbox under a now-dead ref. Let the caller retry
          # stream_download/2 itself instead.
          |> Keyword.merge(auth: {:bearer, token}, into: :self, retry: false)

        case Req.request(request) do
          {:ok, %Req.Response{status: status, body: %Req.Response.Async{} = async}}
          when status in 200..299 ->
            {:ok, async}

          {:ok, %Req.Response{status: 404} = resp} ->
            Req.cancel_async_response(resp)
            {:error, :not_found}

          {:ok, %Req.Response{status: status} = resp} ->
            Req.cancel_async_response(resp)
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end

    @impl true
    def delete(key, %Context{} = ctx) do
      with {:ok, token} <- resolve_token(ctx.service_opts),
           {:ok, id_or_nil} <- resolve_id(key, token, ctx.service_opts) do
        case id_or_nil do
          nil ->
            :ok

          id ->
            case id
                 |> build_delete_request(ctx.service_opts)
                 |> perform(token)
                 |> handle_response() do
              {:ok, _body} -> :ok
              {:error, :not_found} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
      end
    end

    @impl true
    def exists?(key, %Context{} = ctx) do
      opts = ctx.service_opts

      with {:ok, token} <- resolve_token(opts) do
        # A fresh property lookup already filters trashed = false, so a hit
        # there needs no further check. A cached id might be stale (the
        # file could have been deleted on Drive out of band since it was
        # cached), so that path still verifies against the API by id.
        case Keyword.get(opts, :drive_file_id) do
          nil ->
            case lookup_id(key, token, opts) do
              {:ok, nil} -> {:ok, false}
              {:ok, _id} -> {:ok, true}
              {:error, reason} -> {:error, reason}
            end

          id ->
            check_still_exists(id, token, opts)
        end
      end
    end

    @impl true
    def head(key, %Context{} = ctx) do
      with {:ok, token} <- resolve_token(ctx.service_opts),
           {:ok, id} <- require_id(key, token, ctx.service_opts),
           {:ok, body} <-
             id
             |> build_metadata_request(ctx.service_opts)
             |> perform(token)
             |> handle_response()
             |> decoded_map() do
        {:ok,
         %{
           etag: nil,
           content_md5: hex_to_base64_md5(Map.get(body, "md5Checksum")),
           byte_size: parse_int(Map.get(body, "size"))
         }}
      end
    end

    @impl true
    def url(key, %Context{} = ctx) do
      opts = ctx.service_opts

      case Keyword.get(opts, :base_url) do
        nil -> fallback_url(key, opts)
        base_url -> proxied_url(base_url, key, opts)
      end
    end

    @doc """
    Not supported.

    `AshStorage.Operations.prepare_direct_upload/3` creates the blob record
    *before* calling this callback and never merges its return value back
    onto the row, so there would be no way to persist the Drive id a signed
    upload discovers afterward — the same problem `upload/3`'s
    `extra_blob_attrs` mechanism solves for the normal attach path doesn't
    apply here. Upload through `attach/4`, or call `upload/3` directly.
    """
    @impl true
    def direct_upload(_key, %Context{}), do: {:error, :direct_upload_not_supported}

    # -- URL helpers --

    defp proxied_url(base_url, key, opts) do
      plain_url = "#{base_url}/#{key}"

      case Keyword.get(opts, :secret) do
        nil ->
          plain_url

        secret ->
          sign_opts =
            []
            |> maybe_put(:expires_in, Keyword.get(opts, :expires_in))
            |> maybe_put(:disposition, Keyword.get(opts, :disposition))
            |> maybe_put(:filename, Keyword.get(opts, :filename))

          AshStorage.Token.signed_url(plain_url, secret, key, sign_opts)
      end
    end

    # Deliberately local and network-free: `AshStorage.BlobResource.Calculations.Url`
    # (and its `AttachmentUrl`/`VariantUrl` siblings) call this inside a `with`
    # body rather than a clause, so a raise here isn't caught by their `else`
    # and crashes the whole query. Only the cached id is consulted — never a
    # lookup — to avoid a per-record network call from a list query.
    defp fallback_url(key, opts) do
      case Keyword.get(opts, :drive_file_id) do
        nil ->
          raise ArgumentError,
                "could not generate a Google Drive URL for #{inspect(key)}: no :base_url " <>
                  "configured and no cached :drive_file_id available. Configure :base_url " <>
                  "to point at your own proxy, or call url/2 with a context built from a " <>
                  "blob record that has already been uploaded."

        id ->
          "https://drive.google.com/file/d/#{id}/view"
      end
    end

    # -- Credential resolution --

    # A raw token wins for this call; otherwise a live fetch from the named
    # Goth server. Only :goth (a server name/reference, not a secret) is ever
    # persisted on blob records, matching how S3/AzureBlob keep raw
    # credentials out of persisted service_opts.
    defp resolve_token(opts) do
      case Keyword.get(opts, :access_token) do
        nil ->
          case Keyword.get(opts, :goth) do
            nil -> {:error, :missing_credentials}
            name -> fetch_goth_token(resolve_goth_name(name))
          end

        token ->
          {:ok, token}
      end
    end

    defp resolve_goth_name(name) when is_atom(name), do: name

    defp resolve_goth_name(name) when is_binary(name) do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> name
    end

    # Goth registers through its own Registry, not as a named process --
    # Process.whereis/1 would report nil while Goth is running fine, so we
    # never probe that way. An unstarted or misnamed server surfaces as an
    # exit or an ArgumentError from the underlying {:via, Registry, _}
    # lookup, not as {:error, _}, so both are caught here explicitly.
    defp fetch_goth_token(name) do
      case goth_module().fetch(name) do
        {:ok, %{token: token}} -> {:ok, token}
        {:error, reason} -> {:error, {:goth_error, reason}}
      end
    rescue
      e -> {:error, {:goth_unavailable, e}}
    catch
      :exit, reason -> {:error, {:goth_unavailable, reason}}
    end

    # Resolved at runtime rather than written as `Goth.fetch/1` so this module
    # compiles cleanly in applications that don't depend on :goth at all --
    # the :access_token path needs no Goth, and a literal remote call would
    # emit an "undefined module" warning that fails --warnings-as-errors builds.
    defp goth_module, do: Module.concat(["Goth"])

    # -- Id resolution --

    defp require_id(key, token, opts) do
      case resolve_id(key, token, opts) do
        {:ok, nil} -> {:error, :not_found}
        {:ok, id} -> {:ok, id}
        {:error, reason} -> {:error, reason}
      end
    end

    # Prefers the cached id over a property lookup wherever one is
    # available. This matters beyond avoiding an extra request: once a blob
    # record is destroyed, its cached :drive_file_id is the only handle left
    # on the Drive file. delete/2 and exists?/2 used to always re-resolve by
    # lookup, which meant a lookup that came back empty for any transient
    # reason (index lag, a parent mismatch) made a purge report success
    # without actually deleting anything on Drive.
    defp resolve_id(key, token, opts) do
      case Keyword.get(opts, :drive_file_id) do
        nil -> lookup_id(key, token, opts)
        id -> {:ok, id}
      end
    end

    defp lookup_id(key, token, opts) do
      with {:ok, body} <-
             key
             |> build_lookup_request(opts)
             |> perform(token)
             |> handle_response()
             |> decoded_map() do
        case Map.get(body, "files", []) do
          [] -> {:ok, nil}
          [%{"id" => id}] -> {:ok, id}
          many -> {:error, {:ambiguous_key, key, Enum.map(many, & &1["id"])}}
        end
      end
    end

    defp check_still_exists(id, token, opts) do
      case build_exists_request(id, opts) |> perform(token) |> handle_response() do
        {:ok, %{"trashed" => true}} -> {:ok, false}
        {:ok, _body} -> {:ok, true}
        {:error, :not_found} -> {:ok, false}
        {:error, reason} -> {:error, reason}
      end
    end

    # -- Upload body handling --

    defp body_and_length(data) when is_binary(data) or is_list(data),
      do: {data, IO.iodata_length(data)}

    defp body_and_length(%File.Stream{path: path} = stream),
      do: {stream, File.stat!(path).size}

    # -- Resumable upload session --

    # Starts a resumable upload session: a metadata-only POST/PATCH that, on
    # success, carries no useful body but a `location` header with the
    # session URL the actual bytes get PUT to next. Kept separate from
    # handle_response/1 because a caller needs a header here, not a body.
    defp start_resumable_session(token, key, name, mime, size, existing_id, opts) do
      request =
        case existing_id do
          nil -> build_create_session_request(key, name, mime, size, opts)
          id -> build_update_session_request(id, mime, size, opts)
        end

      case perform(request, token) do
        {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
          case Req.Response.get_header(resp, "location") do
            [url | _] -> {:ok, url}
            [] -> {:error, :missing_upload_session_url}
          end

        other ->
          handle_response(other)
      end
    end

    # Streams the bytes to the session URL from start_resumable_session/7.
    # For an in-memory binary/iolist, `data` is sent as-is -- it's already
    # fully materialized (AshStorage.Operations.attach/4 reads the whole
    # upload before calling any service), so writing it to a temp file just
    # to re-stream it from disk would be pure overhead. For a File.Stream,
    # Req streams the body directly from disk without ever holding it whole.
    defp put_bytes(token, session_url, body, size, mime) do
      [
        method: :put,
        url: session_url,
        auth: {:bearer, token},
        headers: [{"content-type", mime}, {"content-length", Integer.to_string(size)}],
        body: body
      ]
      |> Req.request()
      |> handle_response()
    end

    defp perform(opts, token) do
      opts
      |> Keyword.put(:auth, {:bearer, token})
      |> Req.request()
    end

    # -- Request builders --

    # `name` is the human-readable filename -- it's what a person browsing
    # the Shared Drive sees, and it plays no role in id resolution. The
    # AshStorage key goes in `appProperties` instead, under @key_property,
    # so the Shared Drive stays navigable by a person even though the key
    # itself is an opaque generated string.
    @doc false
    def build_create_session_request(key, name, mime, size, opts) do
      [
        method: :post,
        url: upload_base(opts) <> "/files",
        params: %{
          uploadType: "resumable",
          supportsAllDrives: true,
          fields: "id,md5Checksum,size,mimeType"
        },
        headers: [
          {"x-upload-content-type", mime},
          {"x-upload-content-length", Integer.to_string(size)}
        ],
        json: %{
          key_property_atom(opts) => %{@key_property => key},
          name: name,
          mimeType: mime,
          parents: [Keyword.get(opts, :folder_id) || Keyword.fetch!(opts, :shared_drive_id)]
        }
      ]
    end

    # An update must not resend :parents (illegal on a PATCH) or :name (the
    # display name is a human's to change -- a re-upload must not clobber a
    # rename made in the Drive UI). :appProperties is likewise omitted:
    # Drive's update semantics leave unspecified fields unchanged rather
    # than clearing them, so the key stored there survives untouched.
    @doc false
    def build_update_session_request(id, mime, size, opts) do
      [
        method: :patch,
        url: upload_base(opts) <> "/files/#{id}",
        params: %{
          uploadType: "resumable",
          supportsAllDrives: true,
          fields: "id,md5Checksum,size,mimeType"
        },
        headers: [
          {"x-upload-content-type", mime},
          {"x-upload-content-length", Integer.to_string(size)}
        ],
        json: %{mimeType: mime}
      ]
    end

    @doc false
    def build_lookup_request(key, opts) do
      [
        method: :get,
        url: api_base(opts) <> "/files",
        params: %{
          q: lookup_query(key, opts),
          corpora: "drive",
          driveId: Keyword.fetch!(opts, :shared_drive_id),
          includeItemsFromAllDrives: true,
          supportsAllDrives: true,
          fields: "files(id,name,size,mimeType,md5Checksum)",
          pageSize: 2
        }
      ]
    end

    defp lookup_query(key, opts) do
      parent = Keyword.get(opts, :folder_id) || Keyword.fetch!(opts, :shared_drive_id)
      property = key_property_query_name(opts)

      "#{property} has { key='#{@key_property}' and value='#{escape_q(key)}' } " <>
        "and '#{escape_q(parent)}' in parents and trashed = false"
    end

    defp escape_q(value) do
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")
    end

    @doc false
    def build_download_request(id, opts) do
      [
        method: :get,
        url: api_base(opts) <> "/files/#{id}",
        params: %{alt: "media", supportsAllDrives: true}
      ]
    end

    @doc false
    def build_metadata_request(id, opts) do
      [
        method: :get,
        url: api_base(opts) <> "/files/#{id}",
        params: %{
          fields: "id,name,size,mimeType,md5Checksum,version",
          supportsAllDrives: true
        }
      ]
    end

    @doc false
    def build_exists_request(id, opts) do
      [
        method: :get,
        url: api_base(opts) <> "/files/#{id}",
        params: %{fields: "id,trashed", supportsAllDrives: true}
      ]
    end

    @doc false
    def build_delete_request(id, opts) do
      [
        method: :delete,
        url: api_base(opts) <> "/files/#{id}",
        params: %{supportsAllDrives: true}
      ]
    end

    defp api_base(opts), do: Keyword.get(opts, :api_base_url, @default_api_base_url)
    defp upload_base(opts), do: Keyword.get(opts, :upload_base_url, @default_upload_base_url)

    # -- Shared response handling --

    # Maps an HTTP result to our result type, shared by every call this
    # module makes (except the resumable-session request, which needs a
    # header rather than a body -- see start_resumable_session/6). Public
    # (but undocumented) so it can be exercised directly with synthetic
    # %Req.Response{} structs in tests, without needing to mock the network.
    @doc false
    def handle_response({:ok, %Req.Response{status: status, body: body}})
        when status in 200..299 do
      {:ok, body}
    end

    def handle_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}

    def handle_response({:ok, %Req.Response{status: status, body: body}}) do
      Logger.warning("Google Drive request failed with #{status}: #{inspect(body)}")
      {:error, {:http_error, status}}
    end

    def handle_response({:error, reason}), do: {:error, reason}

    # A 2xx body only decodes to a map when Drive (or a fronting proxy on a
    # bad day) actually sent JSON. Without this, a stray HTML error page or
    # empty body would raise BadMapError out of Map.get/Map.fetch! deep in a
    # caller instead of returning a normal {:error, _}.
    defp decoded_map({:ok, body}) when is_map(body), do: {:ok, body}
    defp decoded_map({:ok, body}), do: {:error, {:unexpected_response, body}}
    defp decoded_map({:error, reason}), do: {:error, reason}

    defp verify_md5(_data, nil), do: :ok

    defp verify_md5(data, expected) do
      if Base.encode64(:erlang.md5(data)) == expected,
        do: :ok,
        else: {:error, :checksum_mismatch}
    end

    # Compares Drive's server-reported MD5 (already re-encoded to base64,
    # see hex_to_base64_md5/1) against the caller's expectation, rather than
    # hashing bytes locally -- the bytes were already streamed up, not held
    # whole in memory here to hash. `actual: nil` means Drive didn't report
    # one (Google-native document types only; not a case upload/3 produces),
    # which is left unverified rather than blocking the upload.
    defp verify_remote_md5(_actual, nil), do: :ok
    defp verify_remote_md5(nil, _expected), do: :ok

    defp verify_remote_md5(actual, expected) do
      if actual == expected, do: :ok, else: {:error, :checksum_mismatch}
    end

    # Drive's md5Checksum is lowercase hex; AttachBlob compares against
    # blob.checksum, which is base64 -- re-encode, matching
    # AshStorage.Service.S3's etag_to_md5/1.
    defp hex_to_base64_md5(nil), do: nil

    defp hex_to_base64_md5(hex) do
      case Base.decode16(hex, case: :lower) do
        {:ok, raw} when byte_size(raw) == 16 -> Base.encode64(raw)
        _ -> nil
      end
    end

    defp parse_int(nil), do: nil
    defp parse_int(value) when is_integer(value), do: value

    defp parse_int(value) when is_binary(value) do
      case Integer.parse(value) do
        {n, _} -> n
        :error -> nil
      end
    end

    defp maybe_put(keyword, _key, nil), do: keyword
    defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
  end
end
