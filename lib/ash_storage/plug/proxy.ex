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
  - `:content_type_fallback` - Content-Type used when the key has no recognisable
    extension (default: `"application/octet-stream"`)

  ## Response headers

  Every response carries `X-Content-Type-Options: nosniff`, and only `GET` and
  `HEAD` are answered (`405` otherwise). A file is sent with
  `Content-Disposition: attachment` unless its content type is in `:inline`.

  On a signed mount the token decides: it may force a download and set the
  download name, and the `disposition` and `filename` query parameters are
  ignored. On an unsigned mount `?disposition=attachment` forces a download and
  `?filename=` sets the download name. Neither can make a file render inline.

  A request whose key is empty, contains a control character, starts with `/`
  or `\\`, or has a `..` segment gets `404` before the signature is checked and
  without a call to the service. See [Storage keys](storage-keys.md).

  On a signed mount the content type comes from the token's content type, else
  from the extension of the token's filename, else from the key. On an unsigned
  mount it comes from the key's extension. Generated keys have none, so there
  `:inline` only takes effect for keys with an extension, or through
  `:content_type_fallback` on a mount that holds one kind of file. See
  [Serving files](serving.md).
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
    |> Map.merge(%{service_mod: service_mod, service_opts: service_opts})
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

    if match?({:error, _}, AshStorage.Key.validate_lookup(key)) do
      conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    else
      case SignedRequest.verify(conn, key, opts) do
        {:ok, access} ->
          ctx = AshStorage.Service.Context.new(opts.service_opts)

          case opts.service_mod.download(key, ctx) do
            {:ok, data} ->
              request = ResponseMetadata.request_params(conn, access)

              conn
              |> ResponseMetadata.put_file_headers(
                content_type(request, access, key, opts),
                opts.inline,
                request
              )
              |> Plug.Conn.send_resp(200, data)
              |> Plug.Conn.halt()

            {:error, :not_found} ->
              conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()

            {:error, _reason} ->
              conn |> Plug.Conn.send_resp(502, "Bad Gateway") |> Plug.Conn.halt()
          end

        {:error, _reason} ->
          conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
      end
    end
  end

  # On an unsigned mount the filename comes from the query, and the requester
  # does not get to choose the content type with it.
  defp content_type(request, access, key, opts) do
    ResponseMetadata.content_type(
      declared: request.content_type,
      filename: if(access != :unsigned, do: request.filename),
      key: key,
      fallback: opts.content_type_fallback
    )
  end
end
