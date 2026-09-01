defmodule AshStorage.Test.EncryptedVariantVault do
  @moduledoc false
  # Minimal reversible Cloak-style vault for tests: no real key management, just
  # enough for the Cloak key manager to wrap/unwrap a DEK. Mirrors the
  # CloakTestVault used in the encryption tests.
  def encrypt(data), do: {:ok, "vault:" <> Base.encode64(data)}

  def decrypt("vault:" <> data), do: Base.decode64(data)
  def decrypt(_data), do: {:error, :invalid_ciphertext}
end

defmodule AshStorage.Test.EncryptedVariantPost do
  @moduledoc false
  # An attachment that carries BOTH an encryption layer and a variant, so the
  # variant round-trip exercises the encrypted path: source read (decrypt) →
  # transform → variant write (re-encrypt) through BlobIO.
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  ets do
    private? true
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.Blob)
    attachment_resource(AshStorage.Test.Attachment)

    has_one_attached :document do
      layer(
        {AshStorage.Layer.Encryption,
         key_manager:
           {AshStorage.Encryption.KeyManagers.Cloak,
            vault: AshStorage.Test.EncryptedVariantVault}},
        metadata_key: "doc-envelope"
      )

      variant(:eager_uppercase, AshStorage.Test.UppercaseVariant, generate: :eager)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: []]
  end
end
