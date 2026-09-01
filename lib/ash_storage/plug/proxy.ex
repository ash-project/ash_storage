defmodule AshStorage.Plug.Proxy do
  @moduledoc """
  A Plug that proxies storage downloads through your application.

  The proxy serves storage keys through a configured storage service or through
  a blob record. Its built-in access check is intentionally small:

  - `access: :public` preserves raw key serving.
  - `access: {:signed, secret: secret}` requires an expiring URL token.

  Actor-aware authorization should normally happen before a signed URL is
  minted, or in an application route that authenticates and authorizes before
  calling BlobIO directly. For BlobIO layers that need a principal at read
  time (e.g. envelope-encryption key managers that wrap DEKs per actor),
  configure `:actor_assign` so the proxy threads the conn-resolved actor
  into the `BlobContext` it builds — see the **actor threading** section
  below.

  ## Usage

  For key-only proxy serving, configure a storage service:

      forward "/storage", AshStorage.Plug.Proxy,
        service: {AshStorage.Service.S3, bucket: "my-bucket", region: "us-east-1"},
        access: :public

  This path calls `AshStorage.BlobIO.read_key/4`. It has no blob row, so it is
  not suitable for layers that need persisted blob metadata, such as envelope
  encryption.

  For blob-aware proxy serving, point the proxy at a resource attachment. The
  proxy resolves the blob by key, gets the runtime layer configuration from
  that attachment, and reads through `AshStorage.BlobIO.read/3`:

      forward "/private/storage", AshStorage.Plug.Proxy,
        resource: MyApp.Post,
        attachment: :document,
        access: {:signed, secret: "a-long-secret-key"}

  If a lower-level proxy route cannot map cleanly to one attachment, pass
  `:blob_resource` and explicit `:layers` when layers are needed.

  ## Configuration

  Configure either a key-only route with `:service`, or a blob-aware route with
  `:resource` and `:attachment`. Lower-level blob-aware routes may pass
  `:blob_resource` and explicit `:layers`, but attachment-backed configuration
  is the usual path.

  Access is independent of the serving shape: use `access: :public` for raw key
  serving, or `access: {:signed, secret: secret}` for expiring bearer URLs. A
  bare `secret:` is also accepted as signed access, but cannot be combined with
  `:access`. When neither is configured, the proxy serves publicly; declare the
  intended mode rather than relying on that default.

  ## Actor threading

  Set `:actor_assign` to thread the request's authenticated principal into
  the `BlobContext` the proxy builds for the blob-aware path. Layers that
  read `bctx.actor` (envelope-encryption key managers, actor-scoped service
  context overrides) then run against a real principal instead of `nil`.

      forward "/storage", AshStorage.Plug.Proxy,
        resource: MyApp.Document,
        attachment: :file,
        access: {:signed, secret: "..."},
        actor_assign: :current_user

  `:actor_assign` accepts an atom — a `conn.assigns[atom]` lookup, the
  common Phoenix shape — or a 1-arity function `fn conn -> actor end` for
  custom resolution.

  The proxy itself does **not** authenticate the request. Wire your existing
  auth pipeline (`require_authenticated_user`, `Guardian.Plug.EnsureAuthenticated`,
  etc.) ahead of `forward` in the router, then `:actor_assign` reads the
  assigns key your pipeline populated. A leaked signed URL still grants the
  bytes for the lifetime of the bearer if no outer auth is in place — the
  bearer alone is not authentication.

  ## Bearer lifetime cap

  Set `:max_lifetime_seconds` to refuse signed URLs whose remaining lifetime
  exceeds the cap. Useful as a defense-in-depth lid against URL builders
  that mint long-lived tokens — even if the layer config defaults
  `:expires_in` to one hour, the proxy refuses anything over the cap.

      forward "/storage", AshStorage.Plug.Proxy,
        resource: MyApp.Document,
        attachment: :file,
        access: {:signed, secret: "..."},
        max_lifetime_seconds: 300

  The cap is the *remaining* lifetime at request time (`expires - now`), not
  the originally-minted lifetime. A token minted with a 24-hour expiry and
  presented in its last 4 minutes passes a 300-second cap; one presented in
  its first hour does not. Set the cap close to the smallest legitimate URL
  lifetime in your app.

  ## Inline rendering

  Raster images render inline by default (`inline: :images`); a caller-influenced
  `content_type` outside the policy (`text/html`, `image/svg+xml`,
  `application/pdf`, unknown) is served `Content-Disposition: attachment` so it
  cannot execute inline in the application origin — a stored-XSS vector — and
  `X-Content-Type-Options: nosniff` is always set. Widen or narrow the inline
  set with `:inline` — a content-type allowlist rather than an all-or-nothing
  switch:

      forward "/documents", AshStorage.Plug.Proxy,
        resource: MyApp.Document,
        attachment: :file,
        access: {:signed, secret: "..."},
        inline: :documents   # raster images + application/pdf preview inline

  Accepts `:images` (default), `:documents`, `:none`, or an explicit list; see
  `AshStorage.Plug.ResponseMetadata.inline_content_types/1`. A type outside the
  policy is always `attachment`, and `?disposition=attachment` can force a
  download even for an inline type. Because serving is key-addressed, this policy
  applies to **every** blob reachable through the mount — scope a permissive
  policy to a mount whose key space holds only content you trust to render.
  """

  @behaviour Plug

  require Ash.Query
  require Logger

  alias AshStorage.BlobIO
  alias AshStorage.Info
  alias AshStorage.Plug.ResponseMetadata
  alias AshStorage.Token

  @impl true
  def init(opts) do
    {resource, attachment_def, blob_resource} = resolve_blob_options(opts)
    {service_mod, service_opts} = resolve_service_options(opts, blob_resource)
    layers = Keyword.get(opts, :layers, [])
    access = resolve_access(opts)
    actor_assign = validate_actor_assign(Keyword.get(opts, :actor_assign))
    max_lifetime_seconds = validate_max_lifetime(Keyword.get(opts, :max_lifetime_seconds))

    maybe_enforce_access_requirement(blob_resource, layers, opts)

    %{
      resource: resource,
      attachment: attachment_def,
      blob_resource: blob_resource,
      service_mod: service_mod,
      service_opts: service_opts,
      layers: layers,
      access: access,
      actor_assign: actor_assign,
      max_lifetime_seconds: max_lifetime_seconds,
      inline: ResponseMetadata.inline_content_types(Keyword.get(opts, :inline, :images)),
      content_type_fallback: Keyword.get(opts, :content_type_fallback, "application/octet-stream")
    }
  end

  defp validate_actor_assign(nil), do: nil
  defp validate_actor_assign(key) when is_atom(key), do: key
  defp validate_actor_assign(fun) when is_function(fun, 1), do: fun

  defp validate_actor_assign(other) do
    raise ArgumentError,
          "AshStorage.Plug.Proxy :actor_assign must be an atom (conn assigns key) " <>
            "or a 1-arity function (fn conn -> actor end), got: #{inspect(other)}"
  end

  defp validate_max_lifetime(nil), do: nil

  defp validate_max_lifetime(seconds) when is_integer(seconds) and seconds > 0,
    do: seconds

  defp validate_max_lifetime(other) do
    raise ArgumentError,
          "AshStorage.Plug.Proxy :max_lifetime_seconds must be a positive integer, " <>
            "got: #{inspect(other)}"
  end

  # A blob-aware / encryption-aware route that configures no access is a
  # foot-gun — it serves protected blobs through an unsigned public proxy. The
  # default is fail-closed (`:require`): such a route raises at init unless it
  # declares an access posture. Applications can relax this on their own cadence:
  #
  #     config :ash_storage, :proxy_access_requirement, :require  # :off | :warn | :require
  #
  # An explicit `access:` (or a bare `:secret`), including `access: :public`,
  # always silences this — only a *defaulted* public access on a protected route
  # is flagged.
  defp maybe_enforce_access_requirement(blob_resource, layers, opts) do
    access_configured? = Keyword.has_key?(opts, :access) or Keyword.has_key?(opts, :secret)
    protected_route? = not is_nil(blob_resource) or encryption_layer?(layers)

    if protected_route? and not access_configured? do
      case Application.get_env(:ash_storage, :proxy_access_requirement, :require) do
        :off ->
          :ok

        :warn ->
          Logger.warning("""
          AshStorage.Plug.Proxy is configured for a blob-aware/encryption-aware route \
          without an `:access` declaration, so it will serve those blobs publicly. \
          Configure `access: {:signed, secret: ...}`, or set `access: :public` to \
          acknowledge public serving and silence this warning. To make this an error, \
          set `config :ash_storage, :proxy_access_requirement, :require`.
          """)

        :require ->
          raise ArgumentError,
                "AshStorage.Plug.Proxy requires an explicit `:access` for blob-aware/" <>
                  "encryption-aware routes (config :ash_storage, :proxy_access_requirement, " <>
                  ":require). Configure `access: {:signed, secret: ...}` or `access: :public`."

        other ->
          raise ArgumentError,
                "invalid :ash_storage :proxy_access_requirement #{inspect(other)} " <>
                  "(expected :off, :warn, or :require)"
      end
    else
      :ok
    end
  end

  defp encryption_layer?(layers) do
    Enum.any?(layers, fn
      AshStorage.Layer.Encryption -> true
      {AshStorage.Layer.Encryption, _opts} -> true
      _other -> false
    end)
  end

  @impl true
  def call(conn, opts) do
    key = conn.path_info |> Enum.join("/")

    if key == "" do
      conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    else
      case verify_access(conn, key, opts) do
        :ok ->
          serve_key(conn, key, opts)

        {:error, :forbidden} ->
          forbidden(conn)
      end
    end
  end

  defp serve_key(conn, key, %{blob_resource: nil} = opts) do
    actor = resolve_actor(conn, opts.actor_assign)
    bctx = BlobIO.BlobContext.new(operation: :serve, actor: actor)

    BlobIO.read_key(key, {opts.service_mod, opts.service_opts}, bctx, layers: opts.layers)
    |> send_blob_response(conn, key, opts)
  end

  defp serve_key(conn, key, %{blob_resource: blob_resource} = opts) do
    actor = resolve_actor(conn, opts.actor_assign)

    with {:ok, blob} <- fetch_blob(blob_resource, key),
         bctx =
           BlobIO.BlobContext.new(
             resource: opts.resource,
             attachment: opts.attachment,
             blob: blob,
             actor: actor,
             operation: :serve
           ),
         {:ok, data} <- BlobIO.read(blob, bctx, layers: opts.layers) do
      send_blob_response({:ok, data}, conn, content_path(blob, key), opts, blob)
    else
      {:error, :not_found} ->
        not_found(conn)

      {:error, _reason} ->
        bad_gateway(conn)
    end
  end

  defp send_blob_response(result, conn, path, opts, blob \\ nil)

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp send_blob_response({:ok, data}, conn, path, opts, blob) do
    content_type =
      ResponseMetadata.content_type(path,
        blob: blob,
        fallback: opts.content_type_fallback
      )

    conn
    |> maybe_no_store(opts)
    |> ResponseMetadata.put_nosniff()
    |> Plug.Conn.put_resp_content_type(content_type)
    |> ResponseMetadata.put_content_disposition(
      blob: blob,
      inline: opts.inline,
      content_type: content_type
    )
    |> Plug.Conn.send_resp(200, data)
    |> Plug.Conn.halt()
  end

  defp send_blob_response({:error, :not_found}, conn, _path, _opts, _blob) do
    conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
  end

  defp send_blob_response({:error, _reason}, conn, _path, _opts, _blob) do
    conn |> Plug.Conn.send_resp(502, "Bad Gateway") |> Plug.Conn.halt()
  end

  # A signed URL carries a bearer token in the query string; tell intermediaries not
  # to cache the token-bearing response. Public serving stays cacheable.
  defp maybe_no_store(conn, %{access: {:signed, _signed_opts}}),
    do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store, private")

  defp maybe_no_store(conn, _opts), do: conn

  defp fetch_blob(blob_resource, key) do
    case blob_resource
         |> Ash.Query.filter(key == ^key)
         |> Ash.read_one() do
      {:ok, nil} -> {:error, :not_found}
      {:ok, blob} -> {:ok, blob}
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_path(%{filename: filename}, _key) when is_binary(filename) and filename != "",
    do: filename

  defp content_path(_blob, key), do: key

  defp resolve_blob_options(opts) do
    resource = Keyword.get(opts, :resource)
    attachment_name = Keyword.get(opts, :attachment)
    blob_resource = Keyword.get(opts, :blob_resource)

    case {resource, attachment_name, blob_resource} do
      {nil, nil, blob_resource} ->
        {nil, nil, blob_resource}

      {resource, attachment_name, nil}
      when not is_nil(resource) and not is_nil(attachment_name) ->
        {:ok, attachment_def} = Info.attachment(resource, attachment_name)
        {resource, attachment_def, Info.storage_blob_resource!(resource)}

      {resource, attachment_name, blob_resource}
      when not is_nil(resource) and not is_nil(attachment_name) ->
        {:ok, attachment_def} = Info.attachment(resource, attachment_name)
        {resource, attachment_def, blob_resource}

      {_resource, _attachment_name, _blob_resource} ->
        raise ArgumentError,
              "expected both :resource and :attachment for blob-aware proxy serving"
    end
  end

  defp resolve_service_options(opts, nil) do
    Keyword.fetch!(opts, :service)
  end

  defp resolve_service_options(opts, _blob_resource) do
    Keyword.get(opts, :service, {nil, []})
  end

  defp resolve_access(opts) do
    has_access? = Keyword.has_key?(opts, :access)
    has_secret? = Keyword.has_key?(opts, :secret)

    cond do
      has_access? and has_secret? ->
        raise ArgumentError,
              "pass either :access or :secret to AshStorage.Plug.Proxy, not both"

      has_access? ->
        opts |> Keyword.fetch!(:access) |> normalize_access()

      has_secret? ->
        opts |> Keyword.fetch!(:secret) |> normalize_access_secret()

      true ->
        :public
    end
  end

  defp normalize_access(:public), do: :public

  defp normalize_access({:signed, signed_opts}) when is_list(signed_opts) do
    secret = Keyword.fetch!(signed_opts, :secret)
    normalize_access_secret(secret, signed_opts)
  end

  defp normalize_access({:signed, secret}) when is_binary(secret),
    do: normalize_access_secret(secret)

  defp normalize_access(access) do
    raise ArgumentError,
          "invalid AshStorage.Plug.Proxy :access value #{inspect(access)}"
  end

  defp normalize_access_secret(secret, opts \\ [])

  defp normalize_access_secret(secret, opts) when is_binary(secret) and secret != "" do
    {:signed, Keyword.put(opts, :secret, secret)}
  end

  defp normalize_access_secret(_secret, _opts) do
    raise ArgumentError,
          "expected AshStorage.Plug.Proxy signed access to include a non-empty binary :secret"
  end

  defp verify_access(_conn, _key, %{access: :public}), do: :ok

  defp verify_access(conn, key, %{access: {:signed, signed_opts}} = opts) do
    verify_signature(conn, key, signed_opts, opts.max_lifetime_seconds)
  end

  defp verify_signature(conn, key, signed_opts, max_lifetime_seconds) do
    secret = Keyword.fetch!(signed_opts, :secret)
    params = Plug.Conn.fetch_query_params(conn).query_params
    now = System.system_time(:second)

    with token when is_binary(token) <- params["token"],
         expires when is_binary(expires) <- params["expires"],
         {expires_at, ""} <- Integer.parse(expires),
         true <- expires_at > now,
         true <- within_lifetime_cap?(expires_at, now, max_lifetime_seconds) do
      expected = Token.sign(secret, key, expires_at)

      if Plug.Crypto.secure_compare(token, expected) do
        :ok
      else
        {:error, :forbidden}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  defp within_lifetime_cap?(_expires_at, _now, nil), do: true

  defp within_lifetime_cap?(expires_at, now, cap) when is_integer(cap),
    do: expires_at - now <= cap

  defp resolve_actor(_conn, nil), do: nil
  defp resolve_actor(conn, key) when is_atom(key), do: Map.get(conn.assigns, key)
  defp resolve_actor(conn, fun) when is_function(fun, 1), do: fun.(conn)

  defp not_found(conn), do: conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()

  defp bad_gateway(conn), do: conn |> Plug.Conn.send_resp(502, "Bad Gateway") |> Plug.Conn.halt()

  defp forbidden(conn), do: conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
end
