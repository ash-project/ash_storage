defmodule AshStorage.Encryption do
  @moduledoc """
  Helpers for BlobIO envelope-encrypted blobs.

  `AshStorage.Layer.Encryption` owns the read/write layer mechanics.
  This module owns encryption-specific operations that are not ordinary
  read/write phases.

  ## Rewrapping

  `rewrap/3` updates the persisted wrapped DEK metadata for an encrypted blob
  without downloading, decrypting, or re-uploading the blob bytes. This is useful
  for key rotation and recipient/key-policy changes.

  Rewrap only changes the envelope metadata. It is not a full re-encryption. If
  the ciphertext, algorithm, IV, tag, AAD, or DEK itself must change, write a new
  blob instead.

      {:ok, updated_blob} =
        AshStorage.Encryption.rewrap(blob, bctx,
          layer_metadata_key: "document-envelope",
          layers: [
            {AshStorage.Layer.Encryption,
             layer_metadata_key: "document-envelope",
             key_manager: {MyApp.DocumentKeyManager, policy: new_policy}}
          ],
          ash_opts: [actor: actor, tenant: tenant]
        )

  See the `Encryption` guide for a complete application-driven rewrap
  example.
  """

  alias AshStorage.BlobIO.BlobContext
  alias AshStorage.BlobIO.Support
  alias AshStorage.Encryption.RewrapOperation
  alias AshStorage.Layer
  alias AshStorage.Layer.Encryption, as: EncryptionLayer

  @doc """
  Rewrap an encrypted blob's DEK metadata without changing stored bytes.

  This rotates how the DEK is protected (and which parties it is wrapped for), not the DEK
  itself. It is **not** revocation: a recipient who already unwrapped and retained the DEK can
  still decrypt the unchanged ciphertext. To deny a party that may hold the DEK, re-encrypt the
  blob under a fresh DEK (see the Encryption guide, "Rewrap is not revocation").

  Options:

  - `:layers` - explicit runtime layer specs. If omitted, layers are resolved
    from the `BlobContext` resource and attachment.
  - `:layer_metadata_key` - selects which encryption layer to rewrap when more than one
    is configured.
  - `:ash_opts` - options passed to `Ash.update/3`.
  - `:action` - blob update action, defaults to `:update_metadata`.

  The selected encryption layer's key manager may implement
  `c:AshStorage.Encryption.KeyManager.rewrap_dek/3` for a direct KMS or
  recipient-wrap operation. If it does not, AshStorage falls back to
  `unwrap_dek/3` followed by `wrap_dek/3`.
  """
  def rewrap(blob, %BlobContext{} = bctx, opts \\ []) when is_list(opts) do
    bctx = BlobContext.put_blob(bctx, blob)
    layer_metadata = Support.layer_metadata_from_blob(blob)

    with {:ok, layer_opts, metadata_entry, index} <-
           select_encryption_layer(bctx, opts, layer_metadata),
         operation = %RewrapOperation{
           blob_context: bctx,
           blob: blob,
           layer_metadata_key: Layer.layer_metadata_key({EncryptionLayer, layer_opts}),
           layer_metadata: layer_metadata,
           metadata: entry_metadata(metadata_entry),
           call_opts: opts
         },
         {:ok, operation} <- EncryptionLayer.rewrap(operation, layer_opts) do
      updated_layer_metadata =
        List.replace_at(
          layer_metadata,
          index,
          put_entry_metadata(metadata_entry, operation.metadata)
        )

      metadata = Support.put_layer_metadata(blob.metadata || %{}, updated_layer_metadata)
      ash_opts = Keyword.get(opts, :ash_opts, [])
      action = Keyword.get(opts, :action, :update_metadata)

      Ash.update(blob, %{metadata: metadata}, Keyword.merge(ash_opts, action: action))
    end
  end

  defp select_encryption_layer(%BlobContext{} = bctx, opts, layer_metadata) do
    candidates =
      bctx
      |> Support.layers_for(opts)
      |> Enum.flat_map(&encryption_layer_candidates(&1, layer_metadata))

    case Keyword.fetch(opts, :layer_metadata_key) do
      {:ok, layer_metadata_key} ->
        find_encryption_layer(candidates, to_string(layer_metadata_key))

      :error ->
        case candidates do
          [] ->
            {:error, :encrypted_blob_layer_not_configured}

          [{_layer_metadata_key, layer_opts, metadata_entry, index}] ->
            {:ok, layer_opts, metadata_entry, index}

          many ->
            {:error, {:multiple_encryption_layers, Enum.map(many, &elem(&1, 0))}}
        end
    end
  end

  defp encryption_layer_candidates({EncryptionLayer, layer_opts}, layer_metadata)
       when is_list(layer_opts) do
    layer_metadata_key = Layer.layer_metadata_key({EncryptionLayer, layer_opts})

    for {metadata_entry, index} <- Enum.with_index(layer_metadata),
        entry_layer_metadata_key(metadata_entry) == layer_metadata_key do
      {layer_metadata_key, layer_opts, metadata_entry, index}
    end
  end

  defp encryption_layer_candidates(EncryptionLayer, layer_metadata) do
    encryption_layer_candidates({EncryptionLayer, []}, layer_metadata)
  end

  defp encryption_layer_candidates(_layer, _layer_metadata), do: []

  defp find_encryption_layer(candidates, layer_metadata_key) do
    case Enum.find(candidates, fn {candidate_id, _opts, _entry, _index} ->
           candidate_id == layer_metadata_key
         end) do
      nil ->
        {:error, {:encrypted_blob_layer_not_configured, layer_metadata_key}}

      {_candidate_id, layer_opts, metadata_entry, index} ->
        {:ok, layer_opts, metadata_entry, index}
    end
  end

  defp entry_layer_metadata_key(%{"layer_metadata_key" => layer_metadata_key}),
    do: to_string(layer_metadata_key)

  defp entry_layer_metadata_key(%{layer_metadata_key: layer_metadata_key}),
    do: to_string(layer_metadata_key)

  defp entry_layer_metadata_key(_entry), do: nil

  defp entry_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp entry_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp entry_metadata(_entry), do: %{}

  defp put_entry_metadata(%{"metadata" => _metadata} = entry, metadata) do
    Map.put(entry, "metadata", metadata)
  end

  defp put_entry_metadata(%{metadata: _metadata} = entry, metadata) do
    Map.put(entry, :metadata, metadata)
  end

  defp put_entry_metadata(entry, metadata) when is_map(entry) do
    Map.put(entry, "metadata", metadata)
  end
end
