defmodule AshStorage.EncryptionTest do
  use ExUnit.Case, async: false

  alias AshStorage.BlobIO
  alias AshStorage.Encryption, as: BlobEncryption
  alias AshStorage.Encryption.KeyManagers.Cloak, as: CloakKeyManager
  alias AshStorage.Info
  alias AshStorage.Layer.Encryption, as: EncryptionLayer
  alias AshStorage.Service
  alias AshStorage.Test.LayeredPost
  alias AshStorage.Test.Post

  defmodule CloakTestVault do
    def encrypt(data), do: {:ok, "vault:" <> Base.encode64(data)}

    def decrypt("vault:" <> data), do: Base.decode64(data)
    def decrypt(_data), do: {:error, :invalid_ciphertext}
  end

  defmodule TestKeyManager do
    @behaviour AshStorage.Encryption.KeyManager

    @impl true
    def wrap_dek(dek, write, opts) do
      send(opts[:pid], {:key_manager, :wrap_dek, byte_size(dek), write.blob_context.operation})

      {:ok,
       %{
         "format" => "test",
         "ciphertext" => Base.encode64("wrapped:" <> dek)
       }}
    end

    @impl true
    def unwrap_dek(
          %{"format" => "test", "ciphertext" => ciphertext},
          read,
          opts
        ) do
      send(opts[:pid], {:key_manager, :unwrap_dek, read.blob_context.operation})

      with {:ok, "wrapped:" <> dek} <- Base.decode64(ciphertext) do
        {:ok, dek}
      end
    end
  end

  defmodule PrefixKeyManager do
    @behaviour AshStorage.Encryption.KeyManager

    @impl true
    def wrap_dek(dek, write, opts) do
      prefix = Keyword.fetch!(opts, :prefix)
      send(opts[:pid], {:prefix_key_manager, :wrap_dek, prefix, write.blob_context.operation})

      {:ok,
       %{
         "format" => "prefix",
         "prefix" => prefix,
         "ciphertext" => Base.encode64(prefix <> ":" <> dek)
       }}
    end

    @impl true
    def unwrap_dek(%{"format" => "prefix", "ciphertext" => ciphertext}, read, opts) do
      send(opts[:pid], {:prefix_key_manager, :unwrap_dek, read.blob_context.operation})

      with {:ok, decoded} <- Base.decode64(ciphertext),
           [_prefix, dek] <- :binary.split(decoded, ":") do
        {:ok, dek}
      end
    end
  end

  defmodule OptimizedRewrapKeyManager do
    @behaviour AshStorage.Encryption.KeyManager

    @impl true
    def wrap_dek(dek, write, opts) do
      policy = Keyword.fetch!(opts, :policy)
      send(opts[:pid], {:optimized_key_manager, :wrap_dek, policy, write.blob_context.operation})

      {:ok,
       %{
         "format" => "optimized",
         "policy" => policy,
         "ciphertext" => Base.encode64(dek)
       }}
    end

    @impl true
    def unwrap_dek(%{"format" => "optimized", "ciphertext" => ciphertext}, read, opts) do
      send(opts[:pid], {:optimized_key_manager, :unwrap_dek, read.blob_context.operation})
      Base.decode64(ciphertext)
    end

    @impl true
    def rewrap_dek(%{"format" => "optimized"} = wrapped_dek, operation, opts) do
      policy = Keyword.fetch!(opts, :policy)

      send(
        opts[:pid],
        {:optimized_key_manager, :rewrap_dek, policy, operation.blob_context.operation}
      )

      {:ok, Map.put(wrapped_dek, "policy", policy)}
    end
  end

  defmodule FinalizingKeyManager do
    @behaviour AshStorage.Encryption.KeyManager

    @impl true
    def wrap_dek(dek, write, opts) do
      send(opts[:pid], {:finalizing_key_manager, :wrap_dek, write.blob, byte_size(dek)})

      {:ok,
       %{
         "format" => "external",
         "mode" => "key_grants",
         "subject_kind" => "blob_id"
       }, %{dek: dek, marker: opts[:marker]}}
    end

    @impl true
    def unwrap_dek(_wrapped_dek, _read, _opts), do: {:error, :not_available_in_test}

    @impl true
    def finalize_wrapped_dek(wrapped_dek, operation, opts) do
      send(
        opts[:pid],
        {:finalizing_key_manager, :finalize_wrapped_dek,
         %{
           wrapped_dek: wrapped_dek,
           layer_metadata_key: operation.layer_metadata_key,
           blob_id: operation.context.blob.id,
           blob_context_blob_id: operation.context.blob_context.blob.id,
           blob_key: operation.context.blob.key,
           draft_key: operation.context.draft.key,
           service_mod: operation.context.service.mod,
           metadata_wrapped_dek: operation.metadata["wrapped_dek"],
           handoff_marker: operation.handoff.marker,
           handoff_dek_size: byte_size(operation.handoff.dek)
         }}
      )

      :ok
    end
  end

  defmodule HandoffWithoutFinalizeKeyManager do
    @behaviour AshStorage.Encryption.KeyManager

    @impl true
    def wrap_dek(dek, _write, opts) do
      send(opts[:pid], {:handoff_without_finalize_key_manager, :wrap_dek})
      {:ok, %{"format" => "external"}, dek}
    end

    @impl true
    def unwrap_dek(_wrapped_dek, _read, _opts), do: {:error, :not_available_in_test}
  end

  defmodule OptsCapturingKeyManager do
    @behaviour AshStorage.Encryption.KeyManager

    @impl true
    def wrap_dek(dek, _write, opts) do
      send(opts[:pid], {:opts_capturing, :wrap_dek, opts})
      {:ok, %{"format" => "capture", "ciphertext" => Base.encode64(dek)}}
    end

    @impl true
    def unwrap_dek(%{"format" => "capture", "ciphertext" => ciphertext}, _read, _opts),
      do: Base.decode64(ciphertext)
  end

  setup do
    Service.Test.reset!()
    :ok
  end

  defp layer_metadata(metadata) do
    get_in(metadata, ["ash_storage", "blob_io", "layers"])
  end

  # Return the persisted encryption-layer metadata map for a given layer key.
  defp encryption_metadata(blob, layer_metadata_key) do
    blob.metadata
    |> layer_metadata()
    |> Enum.find(&(&1["layer_metadata_key"] == layer_metadata_key))
    |> Map.fetch!("metadata")
  end

  # Return a copy of `blob` whose persisted encryption-layer metadata map has
  # been transformed by `fun` (used to simulate at-rest tampering / substitution).
  defp tamper_encryption_metadata(blob, layer_metadata_key, fun) do
    layers =
      blob.metadata
      |> layer_metadata()
      |> Enum.map(fn
        %{"layer_metadata_key" => ^layer_metadata_key, "metadata" => metadata} = entry ->
          %{entry | "metadata" => fun.(metadata)}

        entry ->
          entry
      end)

    %{blob | metadata: put_in(blob.metadata, ["ash_storage", "blob_io", "layers"], layers)}
  end

  defp write_cloak_blob(data, layer_metadata_key) do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {CloakKeyManager, vault: CloakTestVault},
       layer_metadata_key: layer_metadata_key}
    ]

    bctx = BlobIO.BlobContext.new(resource: Post, attachment: attachment, operation: :attach)

    {:ok, blob} = BlobIO.write(data, bctx, filename: "tamper.txt", layers: layers)
    {blob, layers, attachment}
  end

  defp download_read_bctx(blob, attachment) do
    BlobIO.BlobContext.new(
      resource: Post,
      attachment: attachment,
      blob: blob,
      operation: :download
    )
  end

  test "layers can be configured on the resource and attachment DSL" do
    {:ok, attachment} = Info.attachment(LayeredPost, :cover_image)

    assert Info.layers_for_attachment(LayeredPost, attachment) == [
             {AshStorage.Test.StaticSuffixLayer, suffix: "-resource"},
             {AshStorage.Test.StaticSuffixLayer, suffix: "-cover"}
           ]

    bctx =
      BlobIO.BlobContext.new(
        resource: LayeredPost,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("data", bctx, filename: "dsl-layer.txt")

    assert {:ok, "data-resource-cover"} = Service.Test.download(blob.key, [])

    read_bctx =
      BlobIO.BlobContext.new(
        resource: LayeredPost,
        attachment: attachment,
        blob: blob,
        operation: :download
      )

    assert {:ok, "data"} = BlobIO.read(blob, read_bctx)

    assert {:ok, "data"} =
             BlobIO.read_key(blob.key, {Service.Test, []}, BlobIO.BlobContext.new(),
               layers: Info.layers_for_attachment(LayeredPost, attachment)
             )
  end

  test "layer definitions normalize metadata keys and implementation options" do
    {:ok, attachment} = Info.attachment(LayeredPost, :encrypted_cover)

    assert [
             {AshStorage.Test.StaticSuffixLayer, suffix: "-resource"},
             {EncryptionLayer, dsl_opts}
           ] = Info.layers_for_attachment(LayeredPost, attachment)

    assert Keyword.fetch!(dsl_opts, :proxy_base_url) == "/storage"
    assert Keyword.fetch!(dsl_opts, :layer_metadata_key) == "encrypted-cover"

    assert Keyword.fetch!(dsl_opts, :key_manager) ==
             {CloakKeyManager, vault: AshStorage.Test.Vault}

    definition = %AshStorage.LayerDefinition{
      module: {
        EncryptionLayer,
        proxy_base_url: "/storage", key_manager: {TestKeyManager, pid: self()}
      },
      metadata_key: "document-envelope"
    }

    assert {:ok, definition} = AshStorage.LayerDefinition.transform(definition)

    assert {EncryptionLayer, opts} = AshStorage.LayerDefinition.runtime_spec(definition)
    assert Keyword.fetch!(opts, :proxy_base_url) == "/storage"
    assert Keyword.fetch!(opts, :layer_metadata_key) == "document-envelope"
    assert Keyword.fetch!(opts, :key_manager) == {TestKeyManager, pid: self()}
  end

  test "encryption layer envelope-encrypts writes and decrypts reads with Cloak key manager" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {CloakKeyManager, vault: CloakTestVault}, layer_metadata_key: "test-vault"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("secret data", bctx,
               filename: "encrypted.txt",
               layers: layers
             )

    assert [
             %{
               "layer_metadata_key" => "test-vault",
               "metadata" => metadata
             }
           ] = layer_metadata(blob.metadata)

    assert {:ok, stored_data} = Service.Test.download(blob.key, Service.Context.new([]))
    assert stored_data != "secret data"

    assert metadata["format"] == "aes-256-gcm"
    assert {:ok, iv} = Base.decode64(metadata["iv"])
    assert {:ok, tag} = Base.decode64(metadata["tag"])
    assert %{"format" => "cloak", "ciphertext" => wrapped_dek} = metadata["wrapped_dek"]
    assert {:ok, wrapped_dek} = Base.decode64(wrapped_dek)
    assert byte_size(iv) == 12
    assert byte_size(tag) == 16
    assert String.starts_with?(wrapped_dek, "vault:")

    read_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :download
      )

    assert {:ok, "secret data"} = BlobIO.read(blob, read_bctx, layers: layers)
  end

  describe "encryption layer fail-closed guarantees" do
    test "round-trips through the default aes-256-gcm format" do
      {blob, layers, attachment} = write_cloak_blob("v2 round trip", "rt-vault")
      assert encryption_metadata(blob, "rt-vault")["format"] == "aes-256-gcm"

      assert {:ok, "v2 round trip"} =
               BlobIO.read(blob, download_read_bctx(blob, attachment), layers: layers)
    end

    test "fails closed on an unknown persisted format" do
      {blob, layers, attachment} = write_cloak_blob("unknown format", "uf-vault")

      tampered =
        tamper_encryption_metadata(blob, "uf-vault", &Map.put(&1, "format", "totally-made-up"))

      assert {:error, {:unsupported_encryption_format, "totally-made-up"}} =
               BlobIO.read(tampered, download_read_bctx(tampered, attachment), layers: layers)
    end

    test "fails closed when stored ciphertext is tampered (checksum gate)" do
      # The stored checksum is computed over the ciphertext, so a flipped byte is
      # caught at download before decryption. The AEAD tag path itself is exercised
      # by the corrupted-tag test below (ciphertext intact, tag tampered).
      {blob, layers, attachment} = write_cloak_blob("flip me", "flip-vault")
      {:ok, <<first, rest::binary>>} = Service.Test.download(blob.key, Service.Context.new([]))

      :ok =
        Service.Test.upload(
          blob.key,
          <<rem(first + 1, 256), rest::binary>>,
          Service.Context.new([])
        )

      assert {:error, :checksum_mismatch} =
               BlobIO.read(blob, download_read_bctx(blob, attachment), layers: layers)
    end

    test "fails closed on a wrong-length tag" do
      {blob, layers, attachment} = write_cloak_blob("short tag", "tag-vault")

      tampered =
        tamper_encryption_metadata(blob, "tag-vault", fn metadata ->
          {:ok, tag} = Base.decode64(metadata["tag"])
          <<truncated::binary-size(byte_size(tag) - 1), _::binary>> = tag
          Map.put(metadata, "tag", Base.encode64(truncated))
        end)

      assert {:error, {:invalid_encryption_layer_metadata, "tag"}} =
               BlobIO.read(tampered, download_read_bctx(tampered, attachment), layers: layers)
    end

    test "fails closed on a wrong-length IV" do
      {blob, layers, attachment} = write_cloak_blob("short iv", "iv-vault")

      tampered =
        tamper_encryption_metadata(blob, "iv-vault", fn metadata ->
          Map.put(metadata, "iv", Base.encode64(:crypto.strong_rand_bytes(8)))
        end)

      assert {:error, {:invalid_encryption_layer_metadata, "iv"}} =
               BlobIO.read(tampered, download_read_bctx(tampered, attachment), layers: layers)
    end

    test "fails to read a corrupted but correct-length tag" do
      {blob, layers, attachment} = write_cloak_blob("corrupt tag", "ctag-vault")

      tampered =
        tamper_encryption_metadata(blob, "ctag-vault", fn metadata ->
          Map.put(metadata, "tag", Base.encode64(:crypto.strong_rand_bytes(16)))
        end)

      assert {:error, :encryption_layer_decryption_failed} =
               BlobIO.read(tampered, download_read_bctx(tampered, attachment), layers: layers)
    end

    test "refuses to write an unknown format" do
      {:ok, attachment} = Info.attachment(Post, :cover_image)

      layers = [
        {EncryptionLayer,
         key_manager: {CloakKeyManager, vault: CloakTestVault},
         layer_metadata_key: "unknown-write-vault",
         format: "totally-made-up"}
      ]

      bctx = BlobIO.BlobContext.new(resource: Post, attachment: attachment, operation: :attach)

      assert {:error, {:unsupported_encryption_format, "totally-made-up"}} =
               BlobIO.write("nope", bctx, filename: "unknown.txt", layers: layers)
    end

    test "fails to read an envelope substituted onto another blob (AAD binding)" do
      {blob_a, layers, attachment} = write_cloak_blob("plaintext A", "sub-vault")
      {blob_b, ^layers, _attachment} = write_cloak_blob("plaintext B", "sub-vault")

      # Move A's complete envelope onto B: ciphertext (storage) + metadata (DB).
      {:ok, bytes_a} = Service.Test.download(blob_a.key, Service.Context.new([]))
      :ok = Service.Test.upload(blob_b.key, bytes_a, Service.Context.new([]))

      a_metadata = encryption_metadata(blob_a, "sub-vault")

      # Carry A's checksum/byte_size too, so the download checksum gate passes and
      # the AAD binding is what actually rejects the substitution (not the checksum).
      substituted =
        blob_b
        |> tamper_encryption_metadata("sub-vault", fn _metadata -> a_metadata end)
        |> Map.merge(%{checksum: blob_a.checksum, byte_size: blob_a.byte_size})

      # Under the empty-AAD legacy format this would decrypt A's plaintext as B.
      # The v2 AAD binds the immutable blob key, so reading B fails closed.
      assert {:error, :encryption_layer_decryption_failed} =
               BlobIO.read(
                 substituted,
                 download_read_bctx(substituted, attachment),
                 layers: layers
               )
    end
  end

  test "duplicate layer metadata keys fail closed on read" do
    layers = [
      {EncryptionLayer,
       layer_metadata_key: "dup", key_manager: {CloakKeyManager, vault: CloakTestVault}},
      {EncryptionLayer,
       layer_metadata_key: "dup", key_manager: {CloakKeyManager, vault: CloakTestVault}}
    ]

    entries = [%{"layer_metadata_key" => "dup", "metadata" => %{}}]

    assert {:error, {:duplicate_blob_io_layer_key, "dup"}} =
             AshStorage.BlobIO.Layers.order_by_metadata(layers, entries)
  end

  test "compile-time verifier rejects an attachment whose layers share a metadata key" do
    # Spark runs verifiers in the parallel-checker phase, so the DslError is
    # emitted as a compile diagnostic rather than raised synchronously to the
    # caller — capture stderr and assert the verifier rejected with our message.
    source = """
    defmodule AshStorage.Test.DuplicateLayerKeyResource do
      use Ash.Resource, data_layer: Ash.DataLayer.Ets, extensions: [AshStorage]

      ets do
        private?(true)
      end

      storage do
        service({AshStorage.Service.Test, []})
        blob_resource(AshStorage.Test.Blob)
        attachment_resource(AshStorage.Test.PolymorphicAttachment)

        # Two layers, neither given a metadata_key, both default to "encryption".
        has_one_attached :doc do
          layer({AshStorage.Layer.Encryption, proxy_base_url: "/s"})
          layer({AshStorage.Layer.Encryption, proxy_base_url: "/s"})
        end
      end

      attributes do
        uuid_primary_key(:id)
      end
    end
    """

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        try do
          Code.eval_string(source)
        rescue
          _ -> :ok
        end
      end)

    assert output =~ ~r/duplicate layer metadata key/i
  end

  test "each blob gets a distinct DEK and IV (no key/nonce reuse across blobs)" do
    {blob_a, layers, attachment} = write_cloak_blob("same plaintext", "dek-dup")
    {blob_b, ^layers, _attachment} = write_cloak_blob("same plaintext", "dek-dup")

    meta_a = encryption_metadata(blob_a, "dek-dup")
    meta_b = encryption_metadata(blob_b, "dek-dup")

    # Distinct per-blob nonce and distinct wrapped DEK (i.e. distinct DEKs).
    assert meta_a["iv"] != meta_b["iv"]
    assert meta_a["wrapped_dek"]["ciphertext"] != meta_b["wrapped_dek"]["ciphertext"]

    # Identical plaintext therefore produces different ciphertext at rest...
    {:ok, stored_a} = Service.Test.download(blob_a.key, Service.Context.new([]))
    {:ok, stored_b} = Service.Test.download(blob_b.key, Service.Context.new([]))
    assert stored_a != stored_b

    # ...and both still decrypt back to the original.
    assert {:ok, "same plaintext"} =
             BlobIO.read(blob_a, download_read_bctx(blob_a, attachment), layers: layers)

    assert {:ok, "same plaintext"} =
             BlobIO.read(blob_b, download_read_bctx(blob_b, attachment), layers: layers)
  end

  test "key manager receives only its own opts, not the encryption layer's" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {OptsCapturingKeyManager, pid: self()},
       layer_metadata_key: "opts-iso",
       proxy_base_url: "/should-not-leak"}
    ]

    bctx = BlobIO.BlobContext.new(resource: Post, attachment: attachment, operation: :attach)

    assert {:ok, _blob} =
             BlobIO.write("opts isolation", bctx, filename: "opts.txt", layers: layers)

    assert_receive {:opts_capturing, :wrap_dek, opts}

    # Only the manager's own configured opts are present; the encryption layer's
    # opts (and any proxy/signing material) never leak into the key manager.
    assert Keyword.get(opts, :pid) == self()
    refute Keyword.has_key?(opts, :layer_metadata_key)
    refute Keyword.has_key?(opts, :proxy_base_url)
    refute Keyword.has_key?(opts, :key_manager)
    refute Keyword.has_key?(opts, :format)
  end

  test "encryption layer delegates key management to configured key manager" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {TestKeyManager, pid: self()}, layer_metadata_key: "test-manager"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("generic key management", bctx,
               filename: "generic-encrypted.txt",
               layers: layers
             )

    assert_receive {:key_manager, :wrap_dek, 32, :attach}

    assert [
             %{
               "layer_metadata_key" => "test-manager",
               "metadata" => %{
                 "format" => "aes-256-gcm",
                 "wrapped_dek" => %{"format" => "test"}
               }
             }
           ] = layer_metadata(blob.metadata)

    read_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :download
      )

    assert {:ok, "generic key management"} = BlobIO.read(blob, read_bctx, layers: layers)
    assert_receive {:key_manager, :unwrap_dek, :download}
  end

  test "encryption layer finalizes wrapped DEK metadata after blob creation" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {FinalizingKeyManager, pid: self(), marker: :initial_grant},
       layer_metadata_key: "external-envelope"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("external envelope", bctx,
               filename: "external-envelope.txt",
               layers: layers
             )

    assert_receive {:finalizing_key_manager, :wrap_dek, nil, 32}

    assert_receive {:finalizing_key_manager, :finalize_wrapped_dek,
                    %{
                      wrapped_dek: %{
                        "format" => "external",
                        "mode" => "key_grants",
                        "subject_kind" => "blob_id"
                      },
                      layer_metadata_key: "external-envelope",
                      blob_id: blob_id,
                      blob_context_blob_id: blob_context_blob_id,
                      blob_key: blob_key,
                      draft_key: draft_key,
                      service_mod: Service.Test,
                      metadata_wrapped_dek: %{"format" => "external"},
                      handoff_marker: :initial_grant,
                      handoff_dek_size: 32
                    }}

    assert blob_id == blob.id
    assert blob_context_blob_id == blob.id
    assert blob_key == blob.key
    assert draft_key == blob.key

    assert [
             %{
               "layer_metadata_key" => "external-envelope",
               "metadata" => %{
                 "format" => "aes-256-gcm",
                 "wrapped_dek" => %{
                   "format" => "external",
                   "mode" => "key_grants",
                   "subject_kind" => "blob_id"
                 }
               }
             }
           ] = layer_metadata(blob.metadata)
  end

  test "encryption layer rejects handoff returns without a finalization callback" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {HandoffWithoutFinalizeKeyManager, pid: self()},
       layer_metadata_key: "missing-finalize"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:error,
            {:invalid_encryption_key_manager, HandoffWithoutFinalizeKeyManager,
             :finalize_wrapped_dek}} =
             BlobIO.write("missing finalization", bctx,
               filename: "missing-finalization.txt",
               layers: layers
             )

    assert_receive {:handoff_without_finalize_key_manager, :wrap_dek}
  end

  test "encryption rewrap updates wrapped DEK metadata without rewriting bytes" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    old_layers = [
      {EncryptionLayer,
       key_manager: {PrefixKeyManager, pid: self(), prefix: "old"}, layer_metadata_key: "rewrap"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("rewrap me", bctx,
               filename: "rewrap.txt",
               layers: old_layers
             )

    assert_receive {:prefix_key_manager, :wrap_dek, "old", :attach}
    assert {:ok, stored_before} = Service.Test.download(blob.key, Service.Context.new([]))

    new_layers = [
      {EncryptionLayer,
       key_manager: {PrefixKeyManager, pid: self(), prefix: "new"}, layer_metadata_key: "rewrap"}
    ]

    rewrap_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :rewrap
      )

    assert {:ok, updated_blob} = BlobEncryption.rewrap(blob, rewrap_bctx, layers: new_layers)

    assert_receive {:prefix_key_manager, :unwrap_dek, :rewrap}
    assert_receive {:prefix_key_manager, :wrap_dek, "new", :rewrap}
    assert {:ok, ^stored_before} = Service.Test.download(blob.key, Service.Context.new([]))

    assert [
             %{
               "layer_metadata_key" => "rewrap",
               "metadata" => %{
                 "wrapped_dek" => %{"format" => "prefix", "prefix" => "new"}
               }
             }
           ] = layer_metadata(updated_blob.metadata)

    read_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: updated_blob,
        operation: :download
      )

    assert {:ok, "rewrap me"} = BlobIO.read(updated_blob, read_bctx, layers: new_layers)
  end

  test "encryption rewrap uses key manager optimized rewrap callback when available" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    old_layers = [
      {EncryptionLayer,
       key_manager: {OptimizedRewrapKeyManager, pid: self(), policy: "old"},
       layer_metadata_key: "optimized-rewrap"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("optimized rewrap", bctx,
               filename: "optimized-rewrap.txt",
               layers: old_layers
             )

    assert_receive {:optimized_key_manager, :wrap_dek, "old", :attach}

    new_layers = [
      {EncryptionLayer,
       key_manager: {OptimizedRewrapKeyManager, pid: self(), policy: "new"},
       layer_metadata_key: "optimized-rewrap"}
    ]

    rewrap_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :rewrap
      )

    assert {:ok, updated_blob} = BlobEncryption.rewrap(blob, rewrap_bctx, layers: new_layers)

    assert_receive {:optimized_key_manager, :rewrap_dek, "new", :rewrap}
    refute_received {:optimized_key_manager, :unwrap_dek, _operation}

    assert [
             %{
               "layer_metadata_key" => "optimized-rewrap",
               "metadata" => %{
                 "wrapped_dek" => %{"format" => "optimized", "policy" => "new"}
               }
             }
           ] = layer_metadata(updated_blob.metadata)
  end

  test "encryption layer rejects key reads without blob metadata" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {CloakKeyManager, vault: CloakTestVault}, layer_metadata_key: "test-vault"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("proxied secret", bctx,
               filename: "proxied-encrypted.txt",
               layers: layers
             )

    read_bctx = BlobIO.BlobContext.new(operation: :serve)

    assert {:error, {:missing_encryption_layer_metadata, "test-vault"}} =
             BlobIO.read_key(blob.key, {Service.Test, []}, read_bctx, layers: layers)
  end

  test "encryption layer serves through proxy URLs" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {CloakKeyManager, vault: CloakTestVault}, layer_metadata_key: "test-vault"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :attach
      )

    assert {:ok, blob} =
             BlobIO.write("secret data", bctx,
               filename: "encrypted-photo.jpg",
               layers: layers
             )

    serve_bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        blob: blob,
        operation: :serve
      )

    assert BlobIO.url(blob, serve_bctx, layers: layers) == nil

    proxy_layers = [
      {EncryptionLayer,
       key_manager: {CloakKeyManager, vault: CloakTestVault},
       layer_metadata_key: "test-vault",
       proxy_base_url: "/encrypted/storage"}
    ]

    expected_url = "/encrypted/storage/#{blob.key}"

    assert {:proxy_url, ^expected_url} =
             BlobIO.serving_strategy(blob, serve_bctx, layers: proxy_layers)

    assert BlobIO.url(blob, serve_bctx, layers: proxy_layers) == expected_url
  end

  test "encryption layer rejects direct upload preparation" do
    {:ok, attachment} = Info.attachment(Post, :cover_image)

    layers = [
      {EncryptionLayer,
       key_manager: {CloakKeyManager, vault: CloakTestVault}, layer_metadata_key: "test-vault"}
    ]

    bctx =
      BlobIO.BlobContext.new(
        resource: Post,
        attachment: attachment,
        operation: :direct_upload
      )

    assert {:error, :encryption_layer_does_not_support_direct_upload} =
             BlobIO.prepare_direct_upload(bctx,
               filename: "encrypted-direct.jpg",
               layers: layers
             )
  end
end
