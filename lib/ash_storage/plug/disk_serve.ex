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
  - `:secret` - secret key for verifying signed URLs. When set, requests
    without a valid signature are rejected with 403.
  - `:inline` - content types that may render in the browser: `:none` (default),
    `:images`, `:documents`, or a list such as `["image/png", "application/pdf"]`.
    Every other type is sent as a download.
  - `:content_type_fallback` - Content-Type used when the path gives none
    (default: `"application/octet-stream"`)

  ## Response headers

  Every response carries `X-Content-Type-Options: nosniff`, and only `GET` and
  `HEAD` are answered (`405` otherwise). A file is sent with
  `Content-Disposition: attachment` unless its content type is in `:inline`;
  `?disposition=attachment` forces a download and `?filename=` sets the download
  name, but a request cannot make a file render inline.

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

  The content type comes from the extension of `?filename=`, else from the
  key. The `filename` parameter is chosen by whoever makes the request and is
  not covered by the signature, so listing an active type such as `text/html`
  or `image/svg+xml` in `:inline` lets a requester render any file on the
  mount as that type. See [Serving files](serving.md).
  """

  @behaviour Plug

  alias AshStorage.Plug.ResponseMetadata
  alias AshStorage.Service.Context
  alias AshStorage.Service.Disk

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)

    Map.merge(ResponseMetadata.init(opts), %{
      root: root,
      secret: Keyword.get(opts, :secret)
    })
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
         :ok <- verify_signature(conn, key, opts),
         {:ok, path} <- Disk.file_path(key, Context.new(root: opts.root)) do
      content_type =
        ResponseMetadata.content_type(
          filename: ResponseMetadata.request_overrides(conn).filename,
          key: key,
          fallback: opts.content_type_fallback
        )

      conn
      |> ResponseMetadata.put_file_headers(content_type, opts.inline)
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

  defp verify_signature(_conn, _key, %{secret: nil}), do: :ok

  defp verify_signature(conn, key, %{secret: secret}) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    with token when is_binary(token) <- params["token"],
         expires when is_binary(expires) <- params["expires"],
         {expires_at, ""} <- Integer.parse(expires),
         true <- expires_at > System.system_time(:second) do
      expected = AshStorage.Token.sign(secret, key, expires_at)

      if Plug.Crypto.secure_compare(token, expected) do
        :ok
      else
        {:error, :forbidden}
      end
    else
      _ -> {:error, :forbidden}
    end
  end
end
