defmodule AshStorage.Plug.Proxy do
  @moduledoc """
  A Plug that proxies file downloads through your application from any storage service.

  Useful when you want to:
  - Keep S3 bucket URLs private
  - Add authentication checks before serving files
  - Provide a consistent URL scheme regardless of storage backend

  ## Usage

  In your router:

      forward "/storage", AshStorage.Plug.Proxy,
        service: {AshStorage.Service.S3, bucket: "my-bucket", region: "us-east-1"}

  With signed URL verification:

      forward "/storage", AshStorage.Plug.Proxy,
        service: {AshStorage.Service.S3, bucket: "my-bucket"},
        secret: "a-long-secret-key"

  ## Options

  - `:service` - (required) the `{module, opts}` tuple for the storage service
  - `:secret` - secret key for verifying signed URLs
  - `:inline` - content types that may render in the browser: `:none` (default),
    `:images`, `:documents`, or a list such as `["image/png", "application/pdf"]`.
    Every other type is sent as a download.
  - `:content_type_fallback` - Content-Type used when the key has no recognisable
    extension (default: `"application/octet-stream"`)

  ## Response headers

  Every response carries `X-Content-Type-Options: nosniff`, and only `GET` and
  `HEAD` are answered (`405` otherwise). A file is sent with
  `Content-Disposition: attachment` unless its content type is in `:inline`;
  `?disposition=attachment` forces a download and `?filename=` sets the download
  name, but a request cannot make a file render inline.

  The content type comes from the key's extension. Generated keys have none, so
  on this plug `:inline` only takes effect for keys with an extension, or through
  `:content_type_fallback` on a mount that holds one kind of file. See
  [Serving files](serving.md).
  """

  @behaviour Plug

  alias AshStorage.Plug.ResponseMetadata

  @impl true
  def init(opts) do
    {service_mod, service_opts} = Keyword.fetch!(opts, :service)

    Map.merge(ResponseMetadata.init(opts), %{
      service_mod: service_mod,
      service_opts: service_opts,
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

  # sobelow_skip ["XSS.SendResp"]
  defp serve(conn, opts) do
    key = conn.path_info |> Enum.join("/")

    if key == "" do
      conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    else
      case verify_signature(conn, opts) do
        :ok ->
          ctx = AshStorage.Service.Context.new(opts.service_opts)

          case opts.service_mod.download(key, ctx) do
            {:ok, data} ->
              content_type =
                ResponseMetadata.content_type(key: key, fallback: opts.content_type_fallback)

              conn
              |> ResponseMetadata.put_file_headers(content_type, opts.inline)
              |> Plug.Conn.send_resp(200, data)
              |> Plug.Conn.halt()

            {:error, :not_found} ->
              conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()

            {:error, _reason} ->
              conn |> Plug.Conn.send_resp(502, "Bad Gateway") |> Plug.Conn.halt()
          end

        {:error, :forbidden} ->
          conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
      end
    end
  end

  defp verify_signature(_conn, %{secret: nil}), do: :ok

  defp verify_signature(conn, %{secret: secret}) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    with token when is_binary(token) <- params["token"],
         expires when is_binary(expires) <- params["expires"],
         {expires_at, ""} <- Integer.parse(expires),
         true <- expires_at > System.system_time(:second) do
      key = conn.path_info |> Enum.join("/")
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
