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
  - `:inline` - content-type inline policy (`:images` (default), `:documents`,
    `:none`, or a list of content types). A type in this policy is served
    `inline`; everything else is `attachment`. `X-Content-Type-Options: nosniff`
    is always set. See `AshStorage.Plug.ResponseMetadata.inline_content_types/1`.
  """

  @behaviour Plug

  alias AshStorage.Plug.ResponseMetadata

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)

    %{
      root: root,
      secret: Keyword.get(opts, :secret),
      inline: ResponseMetadata.inline_content_types(Keyword.get(opts, :inline, :images))
    }
  end

  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule", "XSS.ContentType"]
  @impl true
  def call(conn, opts) do
    with %{key: key, path: path, filename: filename} <- resolve_target(conn.path_info, opts.root),
         :ok <- verify_signature(conn, opts, key) do
      if File.exists?(path) do
        content_type = ResponseMetadata.content_type(filename || key)

        conn
        |> maybe_no_store(opts)
        |> ResponseMetadata.put_nosniff()
        |> Plug.Conn.put_resp_content_type(content_type)
        |> ResponseMetadata.put_content_disposition(inline: opts.inline, content_type: content_type)
        |> Plug.Conn.send_file(200, path)
        |> Plug.Conn.halt()
      else
        conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
      end
    else
      nil -> conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
      {:error, :forbidden} -> conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
    end
  end

  defp resolve_target([], _root), do: nil

  defp resolve_target(path_info, root) do
    key = Enum.join(path_info, "/")

    # Reject keys that would escape `root` before touching the filesystem.
    case safe_join(root, key) do
      nil ->
        nil

      path ->
        if File.exists?(path) do
          %{key: key, path: path, filename: nil}
        else
          {key_parts, filename_parts} = Enum.split(path_info, -1)

          case {key_parts, filename_parts} do
            {[], _} ->
              %{key: key, path: path, filename: nil}

            {key_parts, [filename]} ->
              key = Enum.join(key_parts, "/")

              case safe_join(root, key) do
                nil -> nil
                path -> %{key: key, path: path, filename: filename}
              end
          end
        end
    end
  end

  defp safe_join(root, key) do
    case Path.safe_relative(key, root) do
      {:ok, relative} -> Path.join(root, relative)
      :error -> nil
    end
  end

  # When signing is configured, the URL carries a bearer token in the query string;
  # tell intermediaries not to cache the token-bearing response.
  defp maybe_no_store(conn, %{secret: secret}) when is_binary(secret),
    do: Plug.Conn.put_resp_header(conn, "cache-control", "no-store, private")

  defp maybe_no_store(conn, _opts), do: conn

  defp verify_signature(_conn, %{secret: nil}, _key), do: :ok

  defp verify_signature(conn, %{secret: secret}, key) do
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
