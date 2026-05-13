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

  ## Disposition / filename forwarding

  When the inbound request includes `?disposition=attachment&filename=foo.pdf`,
  those values are merged into the service options before `url/2` is called,
  so backends that support response-header overrides (S3
  `response-content-disposition`, Azure SAS `rscd`) can encode them into the
  generated URL.

  ## Options

  - `:service` - (required) the `{module, opts}` tuple for the storage service.
  - `:secret` - secret key for verifying signed app-level URLs. When set,
    requests without a valid `token`/`expires` query pair are rejected with 403.
  - `:status` - HTTP status to use for the redirect (default: `302`). Use `307`
    if method preservation matters for clients/tools that consume the URL.
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    {service_mod, service_opts} = Keyword.fetch!(opts, :service)

    %{
      service_mod: service_mod,
      service_opts: service_opts,
      secret: Keyword.get(opts, :secret),
      status: Keyword.get(opts, :status, 302)
    }
  end

  @impl true
  def call(conn, opts) do
    key = conn.path_info |> Enum.join("/")

    if key == "" do
      conn |> Plug.Conn.send_resp(404, "Not Found") |> Plug.Conn.halt()
    else
      case verify_signature(conn, opts) do
        :ok ->
          ctx = AshStorage.Service.Context.new(merged_service_opts(conn, opts))
          url = opts.service_mod.url(key, ctx)

          conn
          |> Plug.Conn.put_resp_header("location", url)
          |> Plug.Conn.put_resp_header("cache-control", "no-store, private")
          |> Plug.Conn.send_resp(opts.status, "")
          |> Plug.Conn.halt()

        {:error, :forbidden} ->
          conn |> Plug.Conn.send_resp(403, "Forbidden") |> Plug.Conn.halt()
      end
    end
  end

  defp merged_service_opts(conn, opts) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    opts.service_opts
    |> maybe_put(:disposition, params["disposition"])
    |> maybe_put(:filename, params["filename"])
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, _key, ""), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)

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
