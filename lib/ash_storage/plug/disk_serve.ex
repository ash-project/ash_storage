defmodule AshStorage.Plug.DiskServe do
  @moduledoc """
  A Plug for serving files stored by `AshStorage.Service.Disk`.

  Uses `Plug.Conn.send_file/5` for efficient file serving (sendfile on supported platforms).

  ## Usage

  In your router:

      forward "/files", AshStorage.Plug.DiskServe,
        root: "priv/storage"

  With signed URL verification, and images allowed to render in the browser:

      forward "/files", AshStorage.Plug.DiskServe,
        root: "priv/storage",
        secret: "a-long-secret-key",
        inline: :images

  ## Options

  - `:root` - (required) the root directory where files are stored
  - `:secret` - the secret for verifying signed URLs: a binary, a list of
    binaries (for rotation), or a zero-arity function or `{module, function, args}`
    that returns one. When set, a request without a valid `token` parameter for
    its key gets `403`. See [Signed URLs](serving.md#signed-urls).
  - `:max_lifetime_seconds` - the longest lifetime a signed URL may have been
    issued with, a positive integer. A URL issued for longer gets `403`, however
    much time it has left. Requires `:secret`. See
    [Limiting lifetime](serving.md#limiting-lifetime).
  - `:inline` - content types that may render in the browser: `:none` (default),
    `:images`, `:documents`, or a list such as `["image/png", "application/pdf"]`.
    Every other type is sent as a download.
  - `:content_type_fallback` - Content-Type used when the path gives none
    (default: `"application/octet-stream"`)

  ## Response headers

  Every response carries `X-Content-Type-Options: nosniff`, and only `GET` and
  `HEAD` are answered (`405` otherwise). A file is sent with
  `Content-Disposition: attachment` unless its content type is in `:inline`.

  On a signed mount the token decides: it may force a download and set the
  download name, and the `disposition` and `filename` query parameters are
  ignored. On an unsigned mount `?disposition=attachment` forces a download and
  `?filename=` sets the download name. Neither can make a file render inline.

  ## Keys

  The whole request path below the mount is the storage key, so
  `/files/tenant-1/abc123` serves the key `tenant-1/abc123`. A key that is
  empty, contains a control character, starts with `/` or `\\`, or has a `..`
  segment gets `404` before the signature is checked. The file is then resolved
  by `AshStorage.Service.Disk` with the rules it uses for every other
  operation: a key that names a directory, a path below a file, or a symbolic
  link that leads outside `:root` or has an absolute target gets `404`. See
  [Storage keys](storage-keys.md).

  ## Content type

  On a signed mount the content type comes from the token's content type, else
  from the extension of the token's filename, else from the key. The Disk
  service signs the blob's recorded content type and filename, so `:inline`
  also works for generated keys.

  On an unsigned mount it comes from the extension of `?filename=`, else from
  the key. That parameter is chosen by whoever makes the request, so listing an
  active type such as `text/html` or `image/svg+xml` in `:inline` on an
  unsigned mount lets a requester render any file on it as that type. See
  [Serving files](serving.md).
  """

  @behaviour Plug

  alias AshStorage.Plug.ResponseMetadata
  alias AshStorage.Plug.SignedRequest
  alias AshStorage.Service.Context
  alias AshStorage.Service.Disk

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)

    opts
    |> ResponseMetadata.init()
    |> Map.merge(SignedRequest.init(opts))
    |> Map.put(:root, root)
  end

  @impl true
  def call(conn, opts) do
    conn = ResponseMetadata.put_nosniff(conn)

    if ResponseMetadata.allowed_method?(conn),
      do: serve(conn, opts),
      else: ResponseMetadata.method_not_allowed(conn)
  end

  # sobelow_skip ["Traversal.SendFile"]
  defp serve(conn, opts) do
    key = Enum.join(conn.path_info, "/")

    with :ok <- AshStorage.Key.validate_lookup(key),
         {:ok, access} <- signed_request(conn, key, opts),
         {:ok, path} <- Disk.file_path(key, Context.new(root: opts.root)) do
      request = ResponseMetadata.request_params(conn, access)

      content_type =
        ResponseMetadata.content_type(
          declared: request.content_type,
          filename: request.filename,
          key: key,
          fallback: opts.content_type_fallback
        )

      conn
      |> ResponseMetadata.put_file_headers(content_type, opts.inline, request)
      |> Plug.Conn.send_file(200, path)
      |> Plug.Conn.halt()
    else
      {:error, :forbidden} ->
        conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()

      # A refused key, a missing file, a directory, a link that leaves the root
      # and any other file-system error look the same to the requester.
      {:error, _reason} ->
        conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    end
  end

  defp signed_request(conn, key, opts) do
    case SignedRequest.verify(conn, key, opts) do
      {:ok, access} -> {:ok, access}
      {:error, _reason} -> {:error, :forbidden}
    end
  end
end
