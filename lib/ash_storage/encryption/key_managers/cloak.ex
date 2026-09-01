defmodule AshStorage.Encryption.KeyManagers.Cloak do
  @moduledoc """
  Cloak-style key manager for `AshStorage.Layer.Encryption`.

  This module wraps each generated DEK with a configured Cloak vault module and
  unwraps it on read. It does not perform blob byte encryption itself; the
  generic encryption layer handles the AES-GCM envelope and calls this module
  only for DEK protection.

      layer {AshStorage.Layer.Encryption,
             key_manager: {AshStorage.Encryption.KeyManagers.Cloak, vault: MyApp.Vault}},
            metadata_key: "primary-blob-vault"

  The configured vault is expected to expose Cloak-style `encrypt/1` and
  `decrypt/1` APIs, or their bang variants. `encrypt/2` and `encrypt!/2` are
  also supported when a `:label` option is supplied.
  """

  @behaviour AshStorage.Encryption.KeyManager

  alias AshStorage.BlobIO.Reader
  alias AshStorage.BlobIO.Writer
  alias AshStorage.Encryption.ScrubbedError

  @impl true
  def wrap_dek(dek, %Writer.Operation{}, opts) when is_binary(dek) do
    with {:ok, wrapped_dek} <- call_vault(opts, :encrypt, dek) do
      {:ok,
       %{
         "format" => "cloak",
         "ciphertext" => Base.encode64(wrapped_dek)
       }}
    end
  end

  @impl true
  def unwrap_dek(%{"format" => "cloak", "ciphertext" => ciphertext}, %Reader.Operation{}, opts)
      when is_binary(ciphertext) do
    with {:ok, wrapped_dek} <- decode_base64(ciphertext, "ciphertext") do
      call_vault(opts, :decrypt, wrapped_dek)
    end
  end

  def unwrap_dek(_metadata, %Reader.Operation{}, _opts) do
    {:error, {:invalid_cloak_key_metadata, "wrapped_dek"}}
  end

  defp decode_base64(value, key) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:invalid_cloak_key_metadata, key}}
    end
  end

  defp call_vault(opts, action, data) do
    with {:ok, vault} <- fetch_vault(opts) do
      do_call_vault(vault, action, data, Keyword.get(opts, :label))
    end
  end

  defp fetch_vault(opts) do
    case Keyword.fetch(opts, :vault) do
      {:ok, vault} when is_atom(vault) -> {:ok, vault}
      {:ok, vault} -> {:error, {:invalid_cloak_vault, vault}}
      :error -> {:error, :cloak_vault_required}
    end
  end

  defp do_call_vault(vault, :encrypt, data, label) when not is_nil(label) do
    cond do
      function_exported?(vault, :encrypt, 2) ->
        normalize_vault_result(vault.encrypt(data, label))

      function_exported?(vault, :encrypt!, 2) ->
        {:ok, vault.encrypt!(data, label)}

      true ->
        {:error, {:invalid_cloak_vault, vault, :encrypt}}
    end
  rescue
    exception ->
      {:error,
       {:cloak_vault_exception, vault, :encrypt, ScrubbedError.scrub(exception, __STACKTRACE__)}}
  end

  defp do_call_vault(vault, :encrypt, data, _label) do
    cond do
      function_exported?(vault, :encrypt, 1) ->
        normalize_vault_result(vault.encrypt(data))

      function_exported?(vault, :encrypt!, 1) ->
        {:ok, vault.encrypt!(data)}

      true ->
        {:error, {:invalid_cloak_vault, vault, :encrypt}}
    end
  rescue
    exception ->
      {:error,
       {:cloak_vault_exception, vault, :encrypt, ScrubbedError.scrub(exception, __STACKTRACE__)}}
  end

  defp do_call_vault(vault, :decrypt, data, _label) do
    cond do
      function_exported?(vault, :decrypt, 1) ->
        normalize_vault_result(vault.decrypt(data))

      function_exported?(vault, :decrypt!, 1) ->
        {:ok, vault.decrypt!(data)}

      true ->
        {:error, {:invalid_cloak_vault, vault, :decrypt}}
    end
  rescue
    exception ->
      {:error,
       {:cloak_vault_exception, vault, :decrypt, ScrubbedError.scrub(exception, __STACKTRACE__)}}
  end

  defp normalize_vault_result({:ok, data}) when is_binary(data), do: {:ok, data}
  defp normalize_vault_result({:error, _reason} = error), do: error
  defp normalize_vault_result(data) when is_binary(data), do: {:ok, data}
  defp normalize_vault_result(other),
    do: {:error, {:invalid_cloak_vault_return, ScrubbedError.describe_term(other)}}
end
