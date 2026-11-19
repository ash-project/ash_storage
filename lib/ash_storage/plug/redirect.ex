defmodule AshStorage.Plug.Redirect do
  @moduledoc """
  A Plug that redirects to the storage service's URL instead of proxying file bytes.

  Useful when you want to:
  - Apply application-level auth/signature checks before granting access, but
  - Avoid the cost of streaming bytes through the application (presigned S3/Azure
    URLs let the client fetch directly from the storage service).

  Compared to `AshStorage.Plug.Proxy`, this plug never calls `download/2` on
  the underlying service. It calls `url/2` and issues an HTTP redirect.

  ## Usage

  In your router:

      forward "/storage", AshStorage.Plug.Redirect,
        service: {AshStorage.Service.S3, bucket: "my-bucket", region: "us-east-1"}

  With signed URL verification (matches `AshStorage.Plug.Proxy`):

      forward "/storage", AshStorage.Plug.Redirect,
        service: {AshStorage.Service.S3, bucket: "my-bucket"},
        secret: "a-long-secret-key"

  ## Options

  - `:service` - (required) the `{module, opts}` tuple for the storage service.
  - `:secret` - the secret for verifying signed URLs: a binary, a list of
    binaries (for rotation), or a zero-arity function or `{module, function, args}`
    that returns one. When set, a request without a valid `token` parameter for
    its key gets `403`. See [Signed URLs](serving.md#signed-urls).
  - `:max_lifetime_seconds` - the longest lifetime a signed URL may have been
    issued with, a positive integer. A URL issued for longer gets `403`, however
    much time it has left. Requires `:secret`. See
    [Limiting lifetime](serving.md#limiting-lifetime).
  - `:status` - HTTP status for the redirect (default: `302`)
  - `:inline` - content types that may render in the browser: `:none` (default),
    `:images`, `:documents`, or a list such as `["image/png", "application/pdf"]`.
  - `:content_type_fallback` - content type assumed when the key has no
    recognisable extension (default: `"application/octet-stream"`)

  ## Disposition and content type

  Only `GET` and `HEAD` are answered (`405` otherwise), and the redirect carries
  `X-Content-Type-Options: nosniff`. The file itself is served by the storage
  service, so the plug can only pass its decision to the service's `url/2`:

  - unless the content type is in `:inline`, or when a download is forced, it
    passes `disposition: "attachment"`;
  - for an allowed type it passes `content_type:` with that type and no
    disposition;
  - the filename is passed as `filename:` after removing quotes, backslashes,
    control characters and path separators.

  On a signed mount the token decides whether a download is forced and gives
  the filename; the `disposition` and `filename` query parameters are ignored.
  On an unsigned mount `?disposition=attachment` forces a download, `?filename=`
  gives the filename, and other `?disposition=` values are ignored.

  A request whose key is empty, contains a control character, starts with `/`
  or `\\`, or has a `..` segment gets `404` before the signature is checked and
  without a call to the service. See [Storage keys](storage-keys.md).

  On a signed mount the content type comes from the token's content type, else
  from the extension of the token's filename, else from the key. On an unsigned
  mount it comes from the key's extension. Generated keys have none, so there
  `:inline` only takes effect for keys with an extension, or through
  `:content_type_fallback` on a mount that holds one kind of file.

  Whether the final response honours this depends on the service. Azure SAS
  URLs (`presigned: true`) carry it. A Disk URL leads to
  `AshStorage.Plug.DiskServe`; when the Disk service signs URLs, the
  disposition travels in the token and forces a download there, so inline
  rendering needs `inline:` on both mounts (without a `:secret` the DiskServe
  mount alone decides). S3 URLs, Azure URLs without presigning and
  `AshStorage.Service.Mirror` do not carry it: the object is served with the
  headers stored on it. See [Serving files](serving.md).
  """

  @behaviour Plug

  alias AshStorage.Plug.ResponseMetadata
  alias AshStorage.Plug.SignedRequest

  @impl true
  def init(opts) do
    {service_mod, service_opts} = Keyword.fetch!(opts, :service)

    opts
    |> ResponseMetadata.init()
    |> Map.merge(SignedRequest.init(opts))
    |> Map.merge(%{
      service_mod: service_mod,
      service_opts: service_opts,
      status: Keyword.get(opts, :status, 302)
    })
  end

  @impl true
  def call(conn, opts) do
    conn = ResponseMetadata.put_nosniff(conn)

    if ResponseMetadata.allowed_method?(conn),
      do: serve(conn, opts),
      else: ResponseMetadata.method_not_allowed(conn)
  end

  defp serve(conn, opts) do
    key = conn.path_info |> Enum.join("/")

    if match?({:error, _}, AshStorage.Key.validate_lookup(key)) do
      conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    else
      case SignedRequest.verify(conn, key, opts) do
        {:ok, access} ->
          ctx = AshStorage.Service.Context.new(url_opts(conn, access, key, opts))
          url = opts.service_mod.url(key, ctx)

          conn
          |> Plug.Conn.put_resp_header("location", url)
          |> Plug.Conn.put_resp_header("cache-control", "no-store, private")
          |> Plug.Conn.send_resp(opts.status, "")
          |> Plug.Conn.halt()

        {:error, _reason} ->
          conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
      end
    end
  end

  # The plug never widens: it asks for an attachment unless the type is allowed,
  # and leaves any disposition configured on the service in place otherwise. On
  # an unsigned mount the filename comes from the query, and the requester does
  # not get to choose the content type with it.
  defp url_opts(conn, access, key, opts) do
    request = ResponseMetadata.request_params(conn, access)

    content_type =
      ResponseMetadata.content_type(
        declared: request.content_type,
        filename: if(access != :unsigned, do: request.filename),
        key: key,
        fallback: opts.content_type_fallback
      )

    service_opts = maybe_put(opts.service_opts, :filename, request.filename)

    case ResponseMetadata.disposition(content_type, opts.inline, request.disposition) do
      :attachment -> Keyword.put(service_opts, :disposition, "attachment")
      :inline -> Keyword.put(service_opts, :content_type, content_type)
    end
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
