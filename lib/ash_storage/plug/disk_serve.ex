defmodule AshStorage.Plug.DiskServe do
  @moduledoc """
  A Plug for serving files stored by `AshStorage.Service.Disk`.

  Uses `Plug.Conn.send_file/5` for efficient file serving (sendfile on supported platforms).

  ## Usage

  In your router:

      forward "/files", AshStorage.Plug.DiskServe,
        root: "priv/storage"

  With signed URL verification:

      forward "/files", AshStorage.Plug.DiskServe,
        root: "priv/storage",
        secret: "a-long-secret-key"

  ## Options

  - `:root` - (required) the root directory where files are stored
  - `:secret` - secret key for verifying signed URLs. When set, requests
    without a valid signature are rejected with 403.
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)

    %{
      root: root,
      secret: Keyword.get(opts, :secret)
    }
  end

  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule", "XSS.ContentType"]
  @impl true
  def call(conn, opts) do
    key = conn.path_info |> Enum.join("/")

    if key == "" do
      conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    else
      case verify_signature(conn, opts) do
        :ok ->
          path = Path.join(opts.root, key)

          if File.exists?(path) do
            content_type = MIME.from_path(key)

            conn
            |> Plug.Conn.put_resp_content_type(content_type)
            |> maybe_put_disposition(conn)
            |> Plug.Conn.send_file(200, path)
            |> Plug.Conn.halt()
          else
            conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
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

  defp maybe_put_disposition(conn, _original_conn) do
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
