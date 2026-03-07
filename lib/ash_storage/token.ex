defmodule AshStorage.Token do
  @moduledoc """
  HMAC-based token generation and verification for signed URLs.

  Used by `AshStorage.Service.Disk` and the serving plugs to create
  time-limited, tamper-proof URLs.
  """

  @doc """
  Generate an HMAC signature for a key with an expiration timestamp.
  """
  def sign(secret, key, expires_at) when is_binary(secret) and is_integer(expires_at) do
    message = "#{key}:#{expires_at}"

    :crypto.mac(:hmac, :sha256, secret, message)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Build a signed URL by appending token and expires query parameters.

  ## Options

  - `:expires_in` - seconds until expiration (default: 3600)
  - `:disposition` - `"attachment"` to force download
  - `:filename` - filename for Content-Disposition header
  """
  def signed_url(base_url, secret, key, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 3600)
    expires_at = System.system_time(:second) + expires_in
    token = sign(secret, key, expires_at)

    query =
      [{"token", token}, {"expires", to_string(expires_at)}]
      |> maybe_add("disposition", Keyword.get(opts, :disposition))
      |> maybe_add("filename", Keyword.get(opts, :filename))
      |> URI.encode_query()

    "#{base_url}?#{query}"
  end

  defp maybe_add(params, _key, nil), do: params
  defp maybe_add(params, key, value), do: params ++ [{key, to_string(value)}]
end
