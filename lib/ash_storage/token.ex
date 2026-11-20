defmodule AshStorage.Token do
  @moduledoc """
  Signed tokens for URLs.

  Used by `AshStorage.Service.Disk` and the serving plugs to create
  time-limited, tamper-proof URLs.

  ## Format

  A token is three parts separated by `.`:

      v1.<payload>.<signature>

  - `v1` is the version of the format.
  - `<payload>` is a JSON object of claims, base64url-encoded without padding.
  - `<signature>` is the HMAC-SHA256 of `"v1." <> payload` with the secret,
    base64url-encoded without padding (43 characters).

  Every token is made for one purpose and carries these claims:

  | Claim | Meaning |
  |---|---|
  | `p` | the purpose, such as `"download"` |
  | `i` | when the token was issued, in Unix seconds |
  | `e` | when the token expires, in Unix seconds; it is valid while the time is before `e` |

  The `download` purpose also takes:

  | Claim | Meaning |
  |---|---|
  | `s` | the storage key |
  | `d` | `"attachment"` to force a download |
  | `f` | the download name, also used to guess the content type |
  | `t` | the content type |

  `verify/3` rejects a token with a claim that its purpose does not list. A
  claim added later can restrict what a token allows, and a verifier that
  ignored it would accept what the issuer meant to restrict.

  ## Secrets

  A secret is one of:

  - a non-empty binary;
  - a non-empty list of non-empty binaries: `sign/3` signs with the first one
    and `verify/3` accepts a token signed with any of them;
  - a zero-arity function or an `{module, function, args}` tuple that returns
    one of the two forms above. It is called on every `sign/3` and `verify/3`.

  Anything else raises `ArgumentError`, also when a function returns it. The
  message never contains the secret.

  A list rotates a secret without rejecting the tokens that are still out:

      # 1. verify with both, still sign with the old one
      secret: ["old-secret", "new-secret"]
      # 2. sign with the new one
      secret: ["new-secret", "old-secret"]
      # 3. after the longest lifetime of a token has passed
      secret: "new-secret"

  Use at least 32 random bytes, for example from
  `:crypto.strong_rand_bytes(32) |> Base.url_encode64()`.
  """

  @version "v1"
  @default_expires_in 3600
  @reserved_claims ["p", "i", "e"]

  # The claims each purpose accepts besides `p`, `i` and `e`. A new purpose, or a
  # new claim of an existing one, is added here; changing what an existing claim
  # means needs a new version.
  @purposes %{download: ["s", "d", "f", "t"]}

  @typedoc "A secret, or the secrets of a rotation. See \"Secrets\" above."
  @type secret ::
          String.t()
          | [String.t(), ...]
          | (-> String.t() | [String.t(), ...])
          | {module(), atom(), [term()]}

  @type purpose :: :download

  @typedoc "Claims by name. The names are strings, as in the payload."
  @type claims :: %{optional(String.t()) => term()}

  @type verify_error :: :invalid | :wrong_purpose | :expired | :lifetime_exceeded

  @doc """
  Signs a map of claims, or, with a binary secret, a key and an expiry time.

  With a map of claims, returns a token of the format described above. The
  claims must have string names, must be claims of the purpose, and must not
  be `p`, `i` or `e`, which are set from the options. A claim whose value is
  `nil` is left out.

  ## Options

  - `:purpose` - (required) the purpose, `:download`
  - `:expires_in` - seconds until the token expires, a positive integer
    (default: `3600`)
  - `:issued_at` - the issue time in Unix seconds (default: now)

  Raises `ArgumentError` when a claim or an option is invalid, or when the
  secret is not one of the forms above.

  ## Examples

      iex> token = AshStorage.Token.sign(%{"s" => "covers/3f9a"}, "secret", purpose: :download)
      iex> {:ok, claims} = AshStorage.Token.verify(token, "secret", purpose: :download)
      iex> claims["s"]
      "covers/3f9a"

  `sign(secret, key, expires_at)` returns the HMAC of `"\#{key}:\#{expires_at}"`,
  the signature that `signed_url/4` puts in a URL.
  """
  @spec sign(claims(), secret(), keyword()) :: String.t()
  @spec sign(String.t(), String.t(), integer()) :: String.t()
  def sign(secret, key, expires_at) when is_binary(secret) and is_integer(expires_at) do
    message = "#{key}:#{expires_at}"

    :crypto.mac(:hmac, :sha256, secret, message)
    |> Base.url_encode64(padding: false)
  end

  def sign(claims, secret, opts) do
    purpose = purpose!(opts)
    claims = claims!(claims, purpose)
    expires_in = expires_in!(Keyword.get(opts, :expires_in))
    issued_at = issued_at!(Keyword.get(opts, :issued_at))
    [signing_secret | _] = resolve_secret!(secret)

    payload =
      claims
      |> Map.merge(%{
        "p" => Atom.to_string(purpose),
        "i" => issued_at,
        "e" => issued_at + expires_in
      })
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signed = @version <> "." <> payload
    signed <> "." <> signature(signing_secret, signed)
  end

  @doc """
  Verifies a token made by `sign/3` and returns its claims.

  The checks run in this order, and the first that fails decides the result:

  1. the token has the format above and the signature matches one of the
     secrets, else `{:error, :invalid}`. Nothing in the token is decoded
     before the signature matches;
  2. the payload is a JSON object with a string `p` and integer `i` and `e`,
     else `{:error, :invalid}`;
  3. `p` is the expected purpose, else `{:error, :wrong_purpose}`;
  4. every claim is one the purpose lists, else `{:error, :invalid}`;
  5. the current time is before `e`, else `{:error, :expired}`;
  6. with `:max_lifetime_seconds`, `e - i` is at most that, else
     `{:error, :lifetime_exceeded}`. Only the token's own times are compared,
     so clocks that differ between the issuer and the verifier do not matter.

  ## Options

  - `:purpose` - (required) the purpose the token must have, `:download`
  - `:max_lifetime_seconds` - the longest lifetime a token may have been
    issued with, a positive integer (default: no limit)

  Raises `ArgumentError` when an option is invalid, or when the secret is not
  one of the forms above.
  """
  @spec verify(term(), secret(), keyword()) :: {:ok, claims()} | {:error, verify_error()}
  def verify(token, secret, opts) do
    purpose = purpose!(opts)
    max_lifetime = max_lifetime!(Keyword.get(opts, :max_lifetime_seconds))
    secrets = resolve_secret!(secret)

    with {:ok, payload} <- check_signature(token, secrets),
         {:ok, claims} <- decode_payload(payload),
         :ok <- check_purpose(claims, purpose),
         :ok <- check_claim_names(claims, purpose),
         :ok <- check_expiry(claims) do
      check_lifetime(claims, max_lifetime)
    end
  end

  @doc """
  Build a signed URL by appending token and expires query parameters.

  ## Options

  - `:expires_in` - seconds until expiration (default: 3600)
  - `:disposition` - `"attachment"` to force download
  - `:filename` - filename for Content-Disposition header
  """
  @spec signed_url(String.t(), String.t(), String.t(), keyword()) :: String.t()
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

  defp signature(secret, data) do
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.url_encode64(padding: false)
  end

  # The signature is compared as text, not decoded: several base64url strings
  # decode to the same bytes, and only the one `sign/3` produces is accepted.
  # `:crypto.hash_equals/2` raises on inputs of different sizes, so those are
  # compared first.
  defp check_signature(token, secrets) when is_binary(token) do
    with [@version, payload, presented] <- String.split(token, "."),
         true <-
           Enum.any?(secrets, fn secret ->
             expected = signature(secret, @version <> "." <> payload)

             byte_size(expected) == byte_size(presented) and
               :crypto.hash_equals(expected, presented)
           end) do
      {:ok, payload}
    else
      _ -> {:error, :invalid}
    end
  end

  defp check_signature(_token, _secrets), do: {:error, :invalid}

  defp decode_payload(payload) do
    with {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"p" => p, "i" => i, "e" => e} = claims}
         when is_binary(p) and is_integer(i) and is_integer(e) <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, :invalid}
    end
  end

  defp check_purpose(%{"p" => p}, purpose) do
    if p == Atom.to_string(purpose), do: :ok, else: {:error, :wrong_purpose}
  end

  defp check_claim_names(claims, purpose) do
    known = @reserved_claims ++ Map.fetch!(@purposes, purpose)

    if Enum.all?(Map.keys(claims), &(&1 in known)), do: :ok, else: {:error, :invalid}
  end

  defp check_expiry(%{"e" => e}) do
    if System.system_time(:second) < e, do: :ok, else: {:error, :expired}
  end

  defp check_lifetime(claims, nil), do: {:ok, claims}

  defp check_lifetime(%{"i" => i, "e" => e} = claims, max) do
    if e - i <= max, do: {:ok, claims}, else: {:error, :lifetime_exceeded}
  end

  defp purpose!(opts) when is_list(opts) do
    case Keyword.fetch(opts, :purpose) do
      {:ok, purpose} when is_map_key(@purposes, purpose) ->
        purpose

      {:ok, purpose} when is_atom(purpose) ->
        raise ArgumentError,
              "unknown token purpose #{inspect(purpose)}. Expected one of: " <>
                inspect(Map.keys(@purposes))

      {:ok, _purpose} ->
        raise ArgumentError,
              "invalid :purpose option. Expected one of: #{inspect(Map.keys(@purposes))}"

      :error ->
        raise ArgumentError, "the :purpose option is required"
    end
  end

  defp purpose!(_opts) do
    raise ArgumentError, "expected a keyword list of options as the third argument"
  end

  defp claims!(claims, purpose) when is_map(claims) do
    allowed = Map.fetch!(@purposes, purpose)

    Enum.each(claims, fn {name, _value} ->
      cond do
        not is_binary(name) ->
          raise ArgumentError, "claim names must be strings"

        name in @reserved_claims ->
          raise ArgumentError,
                "the claim #{inspect(name)} is set by sign/3 and cannot be given"

        name not in allowed ->
          raise ArgumentError,
                "unknown claim #{inspect(name)} for the purpose #{inspect(purpose)}. " <>
                  "Expected one of: #{inspect(allowed)}"

        true ->
          :ok
      end
    end)

    claims |> Enum.reject(fn {_name, value} -> is_nil(value) end) |> Map.new()
  end

  defp claims!(_claims, _purpose) do
    raise ArgumentError, "expected a map of claims as the first argument"
  end

  defp expires_in!(nil), do: @default_expires_in
  defp expires_in!(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  defp expires_in!(other) do
    raise ArgumentError,
          "invalid :expires_in option #{inspect(other)}. Expected a positive integer"
  end

  defp issued_at!(nil), do: System.system_time(:second)
  defp issued_at!(seconds) when is_integer(seconds), do: seconds

  defp issued_at!(other) do
    raise ArgumentError, "invalid :issued_at option #{inspect(other)}. Expected an integer"
  end

  defp max_lifetime!(nil), do: nil
  defp max_lifetime!(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  defp max_lifetime!(other) do
    raise ArgumentError,
          "invalid :max_lifetime_seconds option #{inspect(other)}. Expected a positive integer"
  end

  # Resolves a secret to the list of binaries it stands for. Error messages
  # name the expected shape and never the value, which may be a real secret.
  defp resolve_secret!(fun) when is_function(fun, 0), do: secret_value!(fun.(), :function)

  defp resolve_secret!({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: secret_value!(apply(module, function, args), :function)

  defp resolve_secret!(secret), do: secret_value!(secret, :literal)

  defp secret_value!(secret, _source) when is_binary(secret) and secret != "", do: [secret]

  defp secret_value!([_ | _] = secrets, source) do
    if Enum.all?(secrets, &(is_binary(&1) and &1 != "")),
      do: secrets,
      else: invalid_secret!(source)
  end

  defp secret_value!(_secret, source), do: invalid_secret!(source)

  @secret_forms "a non-empty binary or a non-empty list of non-empty binaries"

  defp invalid_secret!(:literal) do
    raise ArgumentError,
          "invalid secret. Expected #{@secret_forms}, " <>
            "or a zero-arity function or {module, function, args} tuple that returns one"
  end

  defp invalid_secret!(:function) do
    raise ArgumentError,
          "the secret function returned an invalid secret. Expected #{@secret_forms}"
  end
end
