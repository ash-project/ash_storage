# Encryption

The encryption layer, `AshStorage.Layer.Encryption`, envelope-encrypts
logical bytes before upload and decrypts service bytes after download. It
generates a random data encryption key (DEK), encrypts with AES-256-GCM,
persists the initialization vector (IV), tag, and envelope metadata, and uses
that metadata on read.

Key management is deliberately separate: key managers wrap and unwrap DEKs so
applications can use Cloak, KMS, tenant-selected key-encryption keys (KEKs),
recipient wrapping, or their own key hierarchy without changing the blob
encryption layer.

Encryption is one of AshStorage's bundled [layers](layers.md), not a
separate subsystem. You enable it by adding the layer to a resource or
attachment's `storage` block; once configured, ordinary attaches, loads, proxy
serving, variants, and analyzers encrypt on write and decrypt on read
automatically, with no changes at the call sites. Storage services keep storing
opaque bytes — only the BlobIO path ever sees plaintext.

See [Layers](layers.md) for the generic layer model.

## Configuration

The bundled Cloak key manager wraps each generated DEK with a configured
Cloak-style vault module:

```elixir
storage do
  service {AshStorage.Service.S3, bucket: "private-blobs"}

  layer {AshStorage.Layer.Encryption,
         proxy_base_url: "/storage",
         key_manager: {AshStorage.Encryption.KeyManagers.Cloak, vault: MyApp.Vault}},
        metadata_key: "primary-blob-vault"
end
```

Use a stable `metadata_key`. Blob records persist it as the layer metadata key
so future reads can match the stored blob back to runtime configuration. Avoid
using vault module names, key-manager modules, plaintext keys, or raw secret
material as durable metadata.

The Cloak key manager is not AshCloak attribute persistence. Applications that
already use AshCloak can often reuse the same underlying Cloak vault module,
but BlobIO stores layer metadata on the blob record and applies encryption in
the blob IO path.

## Persisted envelope metadata

The encryption layer persists envelope metadata inside the layer
metadata entry:

```elixir
%{
  "layer_metadata_key" => "primary-blob-vault",
  "metadata" => %{
    "format" => "aes-256-gcm",
    "iv" => "...",
    "tag" => "...",
    "wrapped_dek" => %{
      "format" => "cloak",
      "ciphertext" => "..."
    }
  }
}
```

The `wrapped_dek` map is durable metadata, but it must remain protected. Store
only ciphertext, key ids, policy ids, recipient ids, public format names, and
other non-secret descriptors there. Runtime vault modules, credentials, KMS
clients, plaintext DEKs, KEKs, and raw secrets belong in configuration or
short-lived secret-bearing infrastructure.

## Algorithm format

The top-level `"format"` is the on-disk algorithm contract. Decryption is
dispatched only from this persisted value against a closed, compiled-in
registry, not from runtime configuration or a request. An unknown or absent
format fails closed with `{:error, {:unsupported_encryption_format, name}}`;
there is no silent fall-through to a default algorithm.

The current (and only) format is `"aes-256-gcm"`: AES-256-GCM with a fresh
random 256-bit DEK and 96-bit IV per blob, and context-bound additional
authenticated data (AAD) that authenticates the blob's identity — a canonical,
length-prefixed encoding of the `format` id, the layer metadata key, and the
immutable blob `key`. Moving a
sealed envelope onto a different blob record, or tampering with the persisted
`format` selector, therefore fails authentication instead of decrypting.

Changing the encryption algorithm is **not** an in-place edit of an existing
blob: a new algorithm is added as a new registry entry with its own `"format"`,
new writes adopt it, and existing blobs keep reading under their stamped format.
Removing a format is a deliberate code change (deleting its registry entry).

## Key managers

Key managers implement `AshStorage.Encryption.KeyManager`:

```elixir
defmodule MyApp.DocumentKeyManager do
  @behaviour AshStorage.Encryption.KeyManager

  @impl true
  def wrap_dek(dek, write, opts) do
    policy = Keyword.fetch!(opts, :policy)

    with {:ok, wrapped} <- MyApp.KMS.wrap(dek, policy, write.blob_context.actor) do
      {:ok,
       %{
         "format" => "my_app_kms",
         "policy_id" => policy.id,
         "ciphertext" => Base.encode64(wrapped)
       }}
    end
  end

  @impl true
  def unwrap_dek(%{"ciphertext" => ciphertext} = wrapped_dek, read, opts) do
    policy = MyApp.Policies.fetch!(wrapped_dek["policy_id"])

    with {:ok, encrypted_dek} <- Base.decode64(ciphertext) do
      MyApp.KMS.unwrap(encrypted_dek, policy, read.blob_context.actor, opts)
    end
  end
end
```

The encryption layer passes the current phase operation to the key manager.
Applications can inspect `operation.blob_context.resource`,
`operation.blob_context.attachment`, `operation.blob_context.actor`,
`operation.blob_context.tenant`, or other context when deciding how to wrap or
unwrap the DEK.

The value stored under `"wrapped_dek"` is key-manager metadata. For simple key
managers it may be a self-contained encrypted DEK. For external-envelope key
managers it may instead be a descriptor that tells the key manager how to find
grant rows or another envelope resource. Runtime modules, credentials, and raw
key material should stay out of persisted blob metadata.

### Post-write finalization

Most key managers can return all durable envelope metadata from `wrap_dek/3`.
External-envelope managers sometimes need the blob row first, for example when
grant rows are keyed by blob id. In that case `wrap_dek/3` can return an
opaque handoff:

```elixir
@impl true
def wrap_dek(dek, write, opts) do
  {:ok,
   %{
     "format" => "my_app_envelope",
     "mode" => "key_grants",
     "subject_kind" => "blob_id"
   }, %{dek: dek, initial_actor: write.blob_context.actor}}
end
```

If a handoff is returned, the key manager must also implement
`finalize_wrapped_dek/3`:

```elixir
@impl true
def finalize_wrapped_dek(wrapped_dek, operation, opts) do
  MyApp.KeyGrants.create_initial_grant(
    blob: operation.context.blob,
    actor: operation.context.blob_context.actor,
    envelope: wrapped_dek,
    handoff: operation.handoff,
    opts: opts
  )
end
```

The handoff is runtime-only. BlobIO carries it from `wrap_dek/3` to
`finalize_wrapped_dek/3` after service upload and blob creation, but it is not
persisted in blob metadata and should not be logged. If finalization fails, the
write returns that error after the service object and blob row have already
been created, so applications that use external envelopes should consider
cleanup and retry behavior.

## Rewrapping envelope metadata

Some key-policy changes should not rewrite blob bytes. Key rotation and
recipient-sharing changes can often keep the same ciphertext and DEK while
changing how that DEK is protected.

Use `AshStorage.Encryption.rewrap/3` for that case:

```elixir
{:ok, attachment} = AshStorage.Info.attachment(MyApp.Document, :file)

bctx =
  AshStorage.BlobIO.BlobContext.new(
    resource: MyApp.Document,
    attachment: attachment,
    blob: blob,
    actor: actor,
    tenant: tenant,
    operation: :rewrap
  )

new_layers = [
  {AshStorage.Layer.Encryption,
   layer_metadata_key: "document-envelope",
   key_manager: {MyApp.DocumentKeyManager,
                 policy: MyApp.DocumentPolicy.shared_with(document, recipients)}}
]

{:ok, updated_blob} =
  AshStorage.Encryption.rewrap(blob, bctx,
    layer_metadata_key: "document-envelope",
    layers: new_layers,
    ash_opts: [actor: actor, tenant: tenant]
  )
```

Rewrap updates only the persisted `wrapped_dek` metadata for the selected
encryption layer. It leaves ciphertext, IV, tag, checksum, byte size, service
object, variants, and analyzer results untouched. If the actual byte
encryption algorithm, IV/tag/AAD inputs, ciphertext, or DEK must change, write
a new encrypted blob instead.

### Rewrap is not revocation

Rewrap changes how the DEK is protected and which parties it is wrapped for, but it does **not**
change the DEK or the ciphertext. A recipient who has already unwrapped and retained the DEK can
still decrypt the bytes. Shrinking the recipient set on a rewrap ends *future* unwrapping through
the key manager; it does **not** deny a party that already holds the DEK.

To deny access to a party that may already hold the DEK, the blob must be **re-encrypted under a
fresh DEK** by writing a new encrypted blob. And note the hard limit: no cryptographic operation
can reclaim plaintext a party has already decrypted. Cryptographic revocation only governs future
reads of the *stored* object.

Key managers may implement `c:AshStorage.Encryption.KeyManager.rewrap_dek/3`
for KMS-native rewraps or recipient-wrap changes that do not expose the DEK to
application code:

```elixir
@impl true
def rewrap_dek(wrapped_dek, operation, opts) do
  new_policy = Keyword.fetch!(opts, :policy)

  with {:ok, new_ciphertext} <-
         MyApp.KMS.rewrap(wrapped_dek, new_policy, operation.blob_context.actor) do
    {:ok,
     wrapped_dek
     |> Map.put("policy_id", new_policy.id)
     |> Map.put("ciphertext", Base.encode64(new_ciphertext))}
  end
end
```

If `rewrap_dek/3` is not implemented, AshStorage falls back to
`unwrap_dek/3` followed by `wrap_dek/3` using the same DEK and the newly
configured key-manager options. This fallback only works for key managers that
can return complete wrapped-DEK metadata immediately. Key managers whose
`wrap_dek/3` requires post-write finalization should implement `rewrap_dek/3`
directly for external-envelope side effects, and may return unchanged
descriptor metadata when the durable blob metadata does not need to change.

## Serving encrypted blobs

Encrypted blobs should not expose direct service URLs unless the application is
intentionally serving encrypted bytes to a client that can decrypt them. The
bundled encryption layer forces URL generation through proxy serving when
`:proxy_base_url` is configured and marks the blob as not servable otherwise.

The proxy must resolve the blob record and call `AshStorage.BlobIO.read/3`.
Decrypting requires the wrapped DEK stored in blob metadata; a key-only service
read does not have enough information.

`proxy_base_url` only chooses an application URL for encrypted reads; it does
not protect that URL by itself. Protect the route in one of these ways:

- Configure `AshStorage.Plug.Proxy` with
  `access: {:signed, secret: secret}` and configure the encryption layer with
  the same access declaration, or with the same value as `:proxy_secret`. URL
  generation will add an expiring bearer token, and the plug will reject
  requests without a valid token.
- Point `proxy_base_url` at an application route that authenticates and
  authorizes the current actor, then resolves the blob and reads through BlobIO
  with the actor and tenant in the `BlobContext`.
- Use another trusted gateway or routing layer that already enforces access.

Signed AshStorage proxy URLs are bearer capabilities. They answer "was this URL
minted by the app and is it still unexpired?", not "may this actor read this
blob right now?". Use an actor-aware route when access must be checked per
request. Conversely, an AshStorage-signed URL is not automatically required when
the proxy route is already protected by application authentication and
authorization.

AshStorage cannot infer from `proxy_base_url` whether the target route is public,
signed, actor-aware, or gateway-protected, so the encryption layer does not
attempt to warn when no proxy secret is configured.

## Direct uploads

The bundled encryption layer rejects direct uploads because server-side
envelope encryption requires the server to see bytes before they reach storage.
Applications that need direct-upload ergonomics with encrypted canonical blobs
can use an application-owned staging workflow: upload to a temporary
service-managed location, then let a server worker write the final blob through
BlobIO.
