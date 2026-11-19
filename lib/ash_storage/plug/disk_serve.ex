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

  The key is the first segment of the request path. A key that is empty,
  contains a control character, starts with `/` or `\\`, is `..`, or names a
  directory gets `404`. See [Storage keys](storage-keys.md).

  The content type comes from the segment after the key (`/<key>/<filename>`),
  else from the key. That segment is chosen by whoever makes the request and is
  not covered by the signature, so listing an active type such as `text/html` or
  `image/svg+xml` in `:inline` lets a requester render any file on the mount as
  that type. See [Serving files](serving.md).
  """

  @behaviour Plug

  alias AshStorage.Plug.ResponseMetadata

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

  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule"]
  defp serve(conn, opts) do
    with [key | segments] <- conn.path_info,
         :ok <- AshStorage.Key.validate_lookup(key),
         :ok <- verify_signature(conn, opts) do
      path = Path.join(opts.root, key)

      if File.regular?(path) do
        content_type =
          ResponseMetadata.content_type(
            filename: List.last(segments),
            key: key,
            fallback: opts.content_type_fallback
          )

        conn
        |> ResponseMetadata.put_file_headers(content_type, opts.inline)
        |> Plug.Conn.send_file(200, path)
        |> Plug.Conn.halt()
      else
        conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
      end
    else
      [] ->
        conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()

      {:error, {:invalid_storage_key, _, _}} ->
        conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()

      {:error, :forbidden} ->
        conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
    end
  end

  defp verify_signature(_conn, %{secret: nil}), do: :ok

  defp verify_signature(conn, %{secret: secret}) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    with token when is_binary(token) <- params["token"],
         expires when is_binary(expires) <- params["expires"],
         {expires_at, ""} <- Integer.parse(expires),
         true <- expires_at > System.system_time(:second) do
      key = hd(conn.path_info)
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
