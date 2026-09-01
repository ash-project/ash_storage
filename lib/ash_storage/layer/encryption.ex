defmodule AshStorage.Layer.Encryption do
  @moduledoc """
  An `AshStorage.Layer` that envelope-encrypts stored bytes.

  This layer owns the blob encryption mechanics: it generates a random data
  encryption key (DEK), encrypts logical bytes with an authenticated cipher
  before upload, persists AEAD metadata on the blob, and decrypts raw service
  bytes back into logical bytes after download. In a stack with multiple layers,
  encryption follows normal layer ordering: it wraps whatever earlier write
  layers produced, and it unwraps before those layers run on read.

  Key management is delegated to a configured key manager. The key manager wraps
  the generated DEK into durable metadata on write, or into a descriptor for an
  external envelope, and unwraps that metadata on read. This lets applications
  share the same encryption mechanics while choosing different
  key-management policies.

      storage do
        service {AshStorage.Service.S3, bucket: "private-blobs"}

        layer {AshStorage.Layer.Encryption,
               proxy_base_url: "/storage",
               key_manager: {AshStorage.Encryption.KeyManagers.Cloak, vault: MyApp.Vault}},
              metadata_key: "primary-blob-vault"
      end

  A stable `metadata_key` is recommended in the storage DSL. Blob records
  persist that key as the layer metadata key plus layer metadata, not
  key-manager modules, vault modules, plaintext keys, or raw secrets. Keeping
  the key stable lets you rename modules or rotate runtime configuration
  without making existing blobs unreadable.

  ## Algorithm agility (the on-disk format contract)

  Every encrypted blob persists a `"format"` string. Decryption is dispatched
  only from that immutable persisted value against a closed, compiled-in
  registry (`@formats`), not from runtime configuration, a request, or a
  "preferred" selector. An unknown or absent format fails closed with a
  structured error; there is no silent fall-through to a default algorithm.
  Removing support for a format is a deliberate code change (deleting its
  registry entry), which makes blobs sealed under it unreadable. The framework
  itself applies no automatic time- or version-based expiry; time- or
  version-based key expiry, where wanted, is a key-manager policy (e.g. a manager
  that declines to unwrap a DEK after a TTL or for a retired key version).

  The current registry:

    * `"aes-256-gcm"` — AES-256-GCM with a fresh random 256-bit DEK and 96-bit IV
      per blob, and a context-bound AAD that authenticates the blob `key`, the
      `format` id, and the layer metadata key (see below). This is the only
      format; it is used for both reads and writes.

  Adding a second algorithm (e.g. ChaCha20-Poly1305 or a streaming format) is a
  new registry entry with its own id — additive, not a breaking change.

  ## AAD / blob-identity binding

  The default format binds the ciphertext to the blob's identity via the GCM
  additional authenticated data: a canonical, length-prefixed encoding of the
  `format` id, the layer metadata key, and the immutable blob `key`. Moving a
  sealed envelope onto a different blob record, or tampering with the persisted
  `format` selector, therefore fails authentication rather than decrypting.

  Because reads need the wrapped DEK from blob metadata, key-only reads through
  `AshStorage.BlobIO.read_key/4` cannot decrypt this layer. Use
  `AshStorage.BlobIO.read/3`, or point `:proxy_base_url` at an application route
  or blob-aware proxy route that resolves the blob and reads through BlobIO.
  When using `AshStorage.Plug.Proxy`, configure `:resource` and `:attachment`,
  or pass explicit `:layers`, so the proxy has the runtime layer configuration
  needed to interpret the blob's persisted layer metadata.

  `:proxy_base_url` does not protect the route by itself. If it points directly
  at `AshStorage.Plug.Proxy` on a public route, configure the plug with
  `access: {:signed, secret: secret}` and configure this layer with the same
  access declaration, or with the same value as `:proxy_secret`, so generated
  URLs carry an expiring bearer token. If the URL points at an application route
  that authenticates and authorizes the actor before calling BlobIO, an
  AshStorage-signed proxy URL is not required.

  Direct uploads are not supported by this layer because server-side encryption
  requires the server to see the bytes before they reach storage.

  See the `Encryption` guide for key-manager examples and
  application-driven DEK rewraps.
  """

  @behaviour AshStorage.Layer

  alias AshStorage.BlobIO.DirectUploads
  alias AshStorage.BlobIO.Operation.{BlobDraft, PostCreate, ServiceState}
  alias AshStorage.BlobIO.Reader
  alias AshStorage.BlobIO.Serving
  alias AshStorage.BlobIO.Writer
  alias AshStorage.Encryption.RewrapOperation
  alias AshStorage.Encryption.ScrubbedError
  alias AshStorage.Encryption.WriteFinalization
  alias AshStorage.Layer

  @dek_bytes 32

  # Closed, compiled-in AEAD format registry. The algorithm for a
  # blob is dispatched ONLY from its immutable persisted "format" — never from
  # runtime config, a request, or a "preferred" selector. Unknown/absent format
  # fails closed. A new algorithm is added as a new entry with its own id; new
  # writes adopt it and existing blobs keep reading under their stamped format.
  # Removing a format is a deliberate code change (delete the entry); there is no
  # time- or version-based auto-expiry.
  @write_format "aes-256-gcm"
  @formats %{
    # AES-256-GCM with a fresh random DEK + 96-bit IV per blob and a context-bound
    # AAD (format id + layer metadata key + blob key — see aad/3).
    "aes-256-gcm" => %{cipher: :aes_256_gcm, iv: 12, tag: 16, aad: :context, write: true}
  }

  # Dispatch handles exactly the registered format's shape (`write: true`,
  # `aad: :context`). Registering a `write: false` (read-only) or `aad: :none`
  # format makes the matches in fetch_write_format/1 and aad/3 non-exhaustive, so
  # the compiler points there to restore the fail-closed branch when it's real.

  @serving_opts [
    :proxy_base_url,
    :proxy_secret,
    :secret,
    :access,
    :expires_in,
    :disposition,
    :filename
  ]

  @impl true
  def default_metadata_key(_opts), do: "encryption"

  # The effective key for this configured instance: the framework applies any
  # configured `:layer_metadata_key` override on top of default_metadata_key/1.
  # Every internal use (persisted metadata, AAD binding, read lookup) must agree
  # on this resolved value, so they all route through here.
  defp resolved_metadata_key(opts), do: Layer.layer_metadata_key({__MODULE__, opts})

  @impl true
  def write(%Writer.Operation{} = write, opts) do
    with {:ok, format_name, format} <- fetch_write_format(opts),
         {:ok, key_manager, key_manager_opts} <- fetch_key_manager(opts),
         dek = :crypto.strong_rand_bytes(@dek_bytes),
         iv = :crypto.strong_rand_bytes(format.iv),
         aad = aad(format, format_name, write_aad_context(write, opts)),
         {encrypted_data, tag} =
           :crypto.crypto_one_time_aead(format.cipher, dek, iv, Layer.data(write), aad, true),
         {:ok, wrapped_dek, finalization} <-
           wrap_dek(key_manager, dek, write, key_manager_opts) do
      metadata = metadata(opts, format_name, iv, tag, wrapped_dek)

      {:ok,
       write
       |> Layer.put_metadata(resolved_metadata_key(opts), metadata)
       |> maybe_finalize(
         opts,
         key_manager,
         key_manager_opts,
         metadata,
         wrapped_dek,
         finalization
       )
       |> Layer.put_data(encrypted_data)}
    end
  end

  @impl true
  def read(%Reader.Operation{} = read, opts) do
    with {:ok, metadata} <- fetch_layer_metadata(read, opts),
         {:ok, format_name} <- fetch_format_name(metadata),
         {:ok, format} <- fetch_format(format_name),
         {:ok, iv} <- decode_fixed(metadata, "iv", format.iv),
         {:ok, tag} <- decode_fixed(metadata, "tag", format.tag),
         {:ok, wrapped_dek} <- fetch_wrapped_dek(metadata),
         {:ok, key_manager, key_manager_opts} <- fetch_key_manager(opts),
         {:ok, dek} <- unwrap_dek(key_manager, wrapped_dek, read, key_manager_opts) do
      aad = aad(format, format_name, read_aad_context(read, opts))

      case :crypto.crypto_one_time_aead(format.cipher, dek, iv, Layer.data(read), aad, tag, false) do
        decrypted_data when is_binary(decrypted_data) ->
          {:ok, Layer.put_data(read, decrypted_data)}

        :error ->
          {:error, :encryption_layer_decryption_failed}
      end
    end
  end

  @impl true
  def serving(%Serving.Operation{} = serving, opts) do
    serving_opts =
      opts
      |> Keyword.take(@serving_opts)
      |> Keyword.merge(serving.call_opts)

    case Keyword.fetch(serving_opts, :proxy_base_url) do
      {:ok, base_url} when is_binary(base_url) ->
        {:ok, %{serving | call_opts: Keyword.put(serving_opts, :serve, :proxy), strategy: nil}}

      _missing_or_invalid ->
        {:ok, %{serving | strategy: :not_servable}}
    end
  end

  @impl true
  def direct_upload(%DirectUploads.Operation{}, _opts) do
    {:error, :encryption_layer_does_not_support_direct_upload}
  end

  @doc false
  def rewrap(%RewrapOperation{} = operation, opts) do
    with {:ok, wrapped_dek} <- fetch_wrapped_dek(operation.metadata),
         {:ok, key_manager, key_manager_opts} <- fetch_key_manager(opts),
         {:ok, wrapped_dek} <- rewrap_dek(key_manager, wrapped_dek, operation, key_manager_opts) do
      {:ok, %{operation | metadata: Map.put(operation.metadata, "wrapped_dek", wrapped_dek)}}
    end
  end

  defp metadata(opts, format_name, iv, tag, wrapped_dek) do
    opts
    |> Keyword.get(:metadata, %{})
    |> ensure_metadata_map()
    |> Map.merge(%{
      "format" => format_name,
      "iv" => Base.encode64(iv),
      "tag" => Base.encode64(tag),
      "wrapped_dek" => wrapped_dek
    })
  end

  defp fetch_layer_metadata(%Reader.Operation{} = read, opts) do
    case Layer.metadata(read, resolved_metadata_key(opts)) do
      [%{"metadata" => metadata} | _] when is_map(metadata) ->
        {:ok, metadata}

      [%{metadata: metadata} | _] when is_map(metadata) ->
        {:ok, metadata}

      [] ->
        {:error, {:missing_encryption_layer_metadata, resolved_metadata_key(opts)}}
    end
  end

  # Dispatch strictly on the persisted format; fail closed on unknown.
  defp fetch_format_name(metadata) do
    case Map.fetch(metadata, "format") do
      {:ok, name} when is_binary(name) -> {:ok, name}
      _missing_or_invalid -> {:error, {:invalid_encryption_layer_metadata, "format"}}
    end
  end

  defp fetch_format(name) do
    case Map.fetch(@formats, name) do
      {:ok, format} -> {:ok, format}
      :error -> {:error, {:unsupported_encryption_format, name}}
    end
  end

  # Write format defaults to @write_format, selectable per-write via the `:format` layer
  # opt; an unknown or non-writable selection fails closed (tested). This is the WRITE side
  # only — decryption always dispatches on the immutable persisted `format`, never on
  # runtime config.
  defp fetch_write_format(opts) do
    name = opts |> Keyword.get(:format, @write_format) |> to_string()

    case Map.fetch(@formats, name) do
      {:ok, %{write: true} = format} -> {:ok, name, format}
      :error -> {:error, {:unsupported_encryption_format, name}}
    end
  end

  # Enforce exact IV/tag lengths for the dispatched format on read.
  defp decode_fixed(metadata, key, expected_size) do
    with {:ok, value} when is_binary(value) <- Map.fetch(metadata, key),
         {:ok, decoded} <- decode_base64(value, key),
         true <- byte_size(decoded) == expected_size do
      {:ok, decoded}
    else
      _too_short_or_invalid -> {:error, {:invalid_encryption_layer_metadata, key}}
    end
  end

  # Canonical, length-prefixed AAD so distinct contexts can't collide,
  # and so a tampered format selector / blob identity fails authentication.
  defp aad(%{aad: :context}, format_name, %{key: key, layer_metadata_key: layer_metadata_key}) do
    length_prefixed(format_name) <>
      length_prefixed(layer_metadata_key) <>
      length_prefixed(key)
  end

  defp length_prefixed(value) when is_binary(value), do: <<byte_size(value)::32, value::binary>>

  defp write_aad_context(%Writer.Operation{draft: %BlobDraft{key: key}}, opts) do
    %{key: to_string(key), layer_metadata_key: resolved_metadata_key(opts)}
  end

  defp read_aad_context(%Reader.Operation{key: key}, opts) do
    %{key: to_string(key), layer_metadata_key: resolved_metadata_key(opts)}
  end

  defp fetch_wrapped_dek(metadata) do
    case Map.fetch(metadata, "wrapped_dek") do
      {:ok, wrapped_dek} when is_map(wrapped_dek) ->
        {:ok, wrapped_dek}

      _missing_or_invalid ->
        {:error, {:invalid_encryption_layer_metadata, "wrapped_dek"}}
    end
  end

  defp decode_base64(value, key) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:invalid_encryption_layer_metadata, key}}
    end
  end

  # Hand the key manager ONLY its own options. The full layer option set
  # carries serving/signing material (`:proxy_secret`, `:secret`, `:access`);
  # a third-party or KMS-backed key manager must never receive it.
  defp fetch_key_manager(opts) do
    case Keyword.fetch(opts, :key_manager) do
      {:ok, {module, key_manager_opts}} when is_atom(module) and is_list(key_manager_opts) ->
        {:ok, module, key_manager_opts}

      {:ok, module} when is_atom(module) ->
        {:ok, module, []}

      {:ok, other} ->
        {:error, {:invalid_encryption_key_manager, other}}

      :error ->
        {:error, :encryption_key_manager_required}
    end
  end

  defp maybe_finalize(
         write,
         _opts,
         _key_manager,
         _key_manager_opts,
         _metadata,
         _wrapped_dek,
         :none
       ) do
    write
  end

  defp maybe_finalize(
         write,
         opts,
         key_manager,
         key_manager_opts,
         metadata,
         wrapped_dek,
         {:handoff, handoff}
       ) do
    layer_metadata_key = resolved_metadata_key(opts)

    # Register a first-class post-create step. The closure captures only this
    # layer's per-write state (key, metadata, handoff); the created blob and the
    # surrounding write state ride along in the PostCreate context the writer
    # builds after Ash.create, carried verbatim on the finalization operation.
    run = fn %PostCreate{} = context ->
      operation = %WriteFinalization{
        context: context,
        layer_metadata_key: layer_metadata_key,
        metadata: metadata,
        handoff: handoff
      }

      finalize_wrapped_dek(key_manager, wrapped_dek, operation, key_manager_opts)
    end

    Layer.finalize(write, layer_metadata_key, run)
  end

  defp wrap_dek(key_manager, dek, %Writer.Operation{} = write, opts) do
    if Code.ensure_loaded?(key_manager) and function_exported?(key_manager, :wrap_dek, 3) do
      normalize_wrap_dek(key_manager.wrap_dek(dek, write, opts), key_manager)
    else
      {:error, {:invalid_encryption_key_manager, key_manager, :wrap_dek}}
    end
  rescue
    exception ->
      {:error,
       {:encryption_key_manager_exception, key_manager, :wrap_dek,
        ScrubbedError.scrub(exception, __STACKTRACE__)}}
  end

  defp unwrap_dek(key_manager, wrapped_dek, %Reader.Operation{} = read, opts) do
    if Code.ensure_loaded?(key_manager) and function_exported?(key_manager, :unwrap_dek, 3) do
      normalize_unwrapped_dek(key_manager.unwrap_dek(wrapped_dek, read, opts), key_manager)
    else
      {:error, {:invalid_encryption_key_manager, key_manager, :unwrap_dek}}
    end
  rescue
    exception ->
      {:error,
       {:encryption_key_manager_exception, key_manager, :unwrap_dek,
        ScrubbedError.scrub(exception, __STACKTRACE__)}}
  end

  defp rewrap_dek(key_manager, wrapped_dek, %RewrapOperation{} = operation, opts) do
    if Code.ensure_loaded?(key_manager) and function_exported?(key_manager, :rewrap_dek, 3) do
      normalize_wrapped_dek(
        key_manager.rewrap_dek(wrapped_dek, operation, opts),
        key_manager,
        :rewrap_dek
      )
    else
      fallback_rewrap_dek(key_manager, wrapped_dek, operation, opts)
    end
  rescue
    exception ->
      {:error,
       {:encryption_key_manager_exception, key_manager, :rewrap_dek,
        ScrubbedError.scrub(exception, __STACKTRACE__)}}
  end

  defp finalize_wrapped_dek(key_manager, wrapped_dek, %WriteFinalization{} = operation, opts) do
    if Code.ensure_loaded?(key_manager) and
         function_exported?(key_manager, :finalize_wrapped_dek, 3) do
      normalize_finalized_dek(
        key_manager.finalize_wrapped_dek(wrapped_dek, operation, opts),
        key_manager
      )
    else
      {:error, {:invalid_encryption_key_manager, key_manager, :finalize_wrapped_dek}}
    end
  rescue
    exception ->
      {:error,
       {:encryption_key_manager_exception, key_manager, :finalize_wrapped_dek,
        ScrubbedError.scrub(exception, __STACKTRACE__)}}
  end

  defp fallback_rewrap_dek(key_manager, wrapped_dek, %RewrapOperation{} = operation, opts) do
    read = %Reader.Operation{
      blob_context: operation.blob_context,
      blob: operation.blob,
      key: operation.blob.key,
      service: %ServiceState{mod: operation.blob.service_name},
      layer_metadata: operation.layer_metadata,
      call_opts: operation.call_opts
    }

    write = %Writer.Operation{
      blob_context: operation.blob_context,
      blob: operation.blob,
      draft: blob_draft(operation.blob),
      service: %ServiceState{mod: operation.blob.service_name},
      layer_metadata: operation.layer_metadata,
      call_opts: operation.call_opts
    }

    with {:ok, dek} <- unwrap_dek(key_manager, wrapped_dek, read, opts),
         {:ok, wrapped_dek, finalization} <- wrap_dek(key_manager, dek, write, opts) do
      case finalization do
        :none ->
          {:ok, wrapped_dek}

        {:handoff, _handoff} ->
          {:error, {:encryption_key_manager_rewrap_requires_finalize, key_manager}}
      end
    end
  end

  defp blob_draft(blob) do
    %BlobDraft{
      key: blob.key,
      filename: blob.filename,
      content_type: blob.content_type,
      checksum: blob.checksum,
      byte_size: blob.byte_size,
      metadata: blob.metadata || %{}
    }
  end

  defp normalize_wrap_dek({:ok, wrapped_dek}, _key_manager) when is_map(wrapped_dek) do
    {:ok, wrapped_dek, :none}
  end

  defp normalize_wrap_dek({:ok, wrapped_dek, handoff}, _key_manager) when is_map(wrapped_dek) do
    {:ok, wrapped_dek, {:handoff, handoff}}
  end

  defp normalize_wrap_dek({:error, _reason} = error, _key_manager), do: error

  defp normalize_wrap_dek(other, key_manager) do
    {:error,
     {:invalid_encryption_key_manager_return, key_manager, :wrap_dek,
      ScrubbedError.describe_term(other)}}
  end

  defp normalize_wrapped_dek({:ok, wrapped_dek}, _key_manager, _callback)
       when is_map(wrapped_dek) do
    {:ok, wrapped_dek}
  end

  defp normalize_wrapped_dek({:error, _reason} = error, _key_manager, _callback), do: error

  defp normalize_wrapped_dek(other, key_manager, callback) do
    {:error,
     {:invalid_encryption_key_manager_return, key_manager, callback,
      ScrubbedError.describe_term(other)}}
  end

  defp normalize_unwrapped_dek({:ok, dek}, _key_manager) when is_binary(dek), do: {:ok, dek}
  defp normalize_unwrapped_dek({:error, _reason} = error, _key_manager), do: error

  defp normalize_unwrapped_dek(other, key_manager) do
    {:error,
     {:invalid_encryption_key_manager_return, key_manager, :unwrap_dek,
      ScrubbedError.describe_term(other)}}
  end

  defp normalize_finalized_dek(:ok, _key_manager), do: :ok
  defp normalize_finalized_dek({:error, _reason} = error, _key_manager), do: error

  defp normalize_finalized_dek(other, key_manager) do
    {:error,
     {:invalid_encryption_key_manager_return, key_manager, :finalize_wrapped_dek,
      ScrubbedError.describe_term(other)}}
  end

  defp ensure_metadata_map(metadata) when is_map(metadata), do: metadata
  defp ensure_metadata_map(_metadata), do: %{}
end
