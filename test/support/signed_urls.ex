defmodule AshStorage.Test.SignedUrls do
  @moduledoc false
  # Request paths for the serving plugs' signed-URL tests.

  alias AshStorage.Token

  @doc "A path for `key` with a valid token, built like the Disk service builds it."
  def signed_path(key, secret, opts \\ []), do: Token.signed_url("/" <> key, secret, key, opts)
end
