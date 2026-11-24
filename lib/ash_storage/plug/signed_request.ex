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

  # Under Phoenix `init/1` runs on every request and its result must be
  # escapable, so the secret is stored as given: a function or MFA is only
  # checked for its shape here and called by `AshStorage.Token` on each request.
  # Error messages never contain the value, which may be a real secret.
  @spec init(keyword()) :: mount()
  def init(opts) do
    secret = Keyword.get(opts, :secret)
    max_lifetime = Keyword.get(opts, :max_lifetime_seconds)

    unless secret_shape?(secret) do
      raise ArgumentError,
            "invalid :secret option. Expected a non-empty binary, a non-empty list of " <>
              "non-empty binaries, a zero-arity function or a {module, function, args} tuple"
    end

    cond do
      is_nil(max_lifetime) ->
        :ok

      not (is_integer(max_lifetime) and max_lifetime > 0) ->
        raise ArgumentError,
              "invalid :max_lifetime_seconds option #{inspect(max_lifetime)}. " <>
                "Expected a positive integer"

      is_nil(secret) ->
        raise ArgumentError, "the :max_lifetime_seconds option requires the :secret option"

      true ->
        :ok
    end

    %{secret: secret, max_lifetime_seconds: max_lifetime}
  end

  defp secret_shape?(nil), do: true
  defp secret_shape?(secret) when is_binary(secret), do: secret != ""

  defp secret_shape?([_ | _] = secrets),
    do: Enum.all?(secrets, &(is_binary(&1) and &1 != ""))

  defp secret_shape?(fun) when is_function(fun, 0), do: true

  defp secret_shape?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: true

  defp secret_shape?(_secret), do: false

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
