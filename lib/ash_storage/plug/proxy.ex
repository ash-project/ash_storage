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
  - `:content_type_fallback` - default Content-Type (default: `"application/octet-stream"`)
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    {service_mod, service_opts} = Keyword.fetch!(opts, :service)

    %{
      service_mod: service_mod,
      service_opts: service_opts,
      secret: Keyword.get(opts, :secret),
      content_type_fallback: Keyword.get(opts, :content_type_fallback, "application/octet-stream")
    }
  end

  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  @impl true
  def call(conn, opts) do
    key = conn.path_info |> Enum.join("/")

    if key == "" do
      conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    else
      case verify_signature(conn, opts) do
        :ok ->
          ctx = AshStorage.Service.Context.new(opts.service_opts)

          case opts.service_mod.download(key, ctx) do
            {:ok, data} ->
              content_type = MIME.from_path(key)

              conn
              |> Plug.Conn.put_resp_content_type(content_type)
              |> maybe_put_disposition(conn)
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

  defp maybe_put_disposition(conn, _conn_with_params) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    case params["disposition"] do
      "attachment" ->
        filename = params["filename"]

        value =
          if filename do
            "attachment; filename=\"#{filename}\""
          else
            "attachment"
          end

        Plug.Conn.put_resp_header(conn, "content-disposition", value)

      _ ->
        conn
    end
  end
end
