defmodule AshStorage.Test.SignedUrls do
  @moduledoc false
  # Request paths for the serving plugs' signed-URL tests.

  alias AshStorage.Token

  @doc "A path for `key` with a valid token, built like the Disk service builds it."
  def signed_path(key, secret, opts \\ []), do: Token.signed_url("/" <> key, secret, key, opts)

  @doc """
  A path for `key` with a token built by the same code as the crafted tokens of
  `rejected_paths/2`, but unaltered, so a mount must accept it.
  """
  def crafted_path(key, secret) do
    "/" <> key <> "?token=" <> craft(claims(key, System.system_time(:second)), secret)
  end

  @doc """
  Paths for `key` that a mount with `secret` must reject, by description.
  """
  def rejected_paths(key, secret) do
    now = System.system_time(:second)
    path = "/" <> key

    for_other_key = token(signed_path("other", secret))
    [_, other_payload, other_signature] = String.split(for_other_key, ".")
    attachment = token(signed_path(key, secret, disposition: "attachment"))
    [_, attachment_payload, attachment_signature] = String.split(attachment, ".")
    {first, rest} = String.split_at(attachment_signature, 1)

    %{
      "no token" => path,
      "a token that is not a string" => path <> "?token[]=x",
      "a malformed token" => path <> "?token=v1.x",
      "another version" => path <> "?token=" <> craft(claims(key, now), secret, "v2"),
      "an unknown claim" =>
        path <> "?token=" <> craft(Map.put(claims(key, now), "zz", "x"), secret),
      "the format before v1" =>
        path <> "?token=#{hmac(secret, "#{key}:#{now + 3600}")}&expires=#{now + 3600}",
      "a payload edited to another key" =>
        path <> "?token=v1.#{edit(other_payload, &Map.put(&1, "s", key))}.#{other_signature}",
      "a payload with its disposition removed" =>
        path <>
          "?token=v1.#{edit(attachment_payload, &Map.delete(&1, "d"))}.#{attachment_signature}",
      "an edited signature" =>
        path <>
          "?token=v1.#{attachment_payload}.#{if(first == "A", do: "B", else: "A")}#{rest}",
      "a token for another key" => path <> "?token=" <> for_other_key,
      "another secret" => signed_path(key, "another-secret"),
      "an expired token" =>
        path <>
          "?token=" <>
          Token.sign(%{"s" => key}, secret, purpose: :download, issued_at: now - 7200),
      "another purpose" =>
        path <>
          "?token=" <>
          craft(Map.put(claims(key, now), "p", "blob"), secret)
    }
  end

  defp token(path),
    do: path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("token")

  defp edit(payload, fun) do
    payload
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> fun.()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp claims(key, now), do: %{"p" => "download", "i" => now, "e" => now + 3600, "s" => key}

  # Signs any payload, also ones `Token.sign/3` refuses to make.
  defp craft(claims, secret, version \\ "v1") do
    signed = version <> "." <> Base.url_encode64(Jason.encode!(claims), padding: false)
    signed <> "." <> hmac(secret, signed)
  end

  defp hmac(secret, data),
    do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.url_encode64(padding: false)
end
