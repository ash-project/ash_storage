defmodule AshStorage.Plug.SignedRequest do
  @moduledoc false
  # The signed-URL check shared by the serving plugs. A mount without a secret
  # accepts every request and never reads the `token` parameter.

  alias AshStorage.Token

  @type mount :: %{
          secret: Token.secret() | nil,
          max_lifetime_seconds: pos_integer() | nil
        }
  @type access :: :unsigned | Token.claims()

  @spec init(keyword()) :: mount()
  def init(opts) do
    %{secret: Keyword.get(opts, :secret), max_lifetime_seconds: nil}
  end

  @spec verify(Plug.Conn.t(), String.t(), map()) ::
          {:ok, access()}
          | {:error, :missing | :wrong_subject | Token.verify_error()}
  def verify(_conn, _key, %{secret: nil}), do: {:ok, :unsigned}

  def verify(conn, key, %{secret: secret} = mount) do
    case Plug.Conn.fetch_query_params(conn).query_params["token"] do
      token when is_binary(token) ->
        opts = [purpose: :download, max_lifetime_seconds: mount.max_lifetime_seconds]

        with {:ok, claims} <- Token.verify(token, secret, opts) do
          if claims["s"] == key, do: {:ok, claims}, else: {:error, :wrong_subject}
        end

      _ ->
        {:error, :missing}
    end
  end
end
