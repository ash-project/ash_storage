# FAQ

Common questions about AshStorage's IO path, layers, and encryption — including
the things it does **not** do yet. For overall feature status and what's planned,
see the roadmap in the project README.

## Can I stream large files, or write without buffering the whole object?

Whether you need to stream *through the application* at all depends on the blob:

- **Unlayered blobs** don't have to flow through the app. Hand the client a direct
  service URL (`AshStorage.Plug.Redirect` → e.g. a presigned S3/Azure URL) and the
  backend streams the bytes to the client directly — no application memory ceiling,
  and `Range`/seek works (see the byte-range question below). This is the path for
  large unlayered downloads, and **direct uploads** are the equivalent on the write
  side (see the file-size question below).
- **Through BlobIO** — proxy serving, or any layered/encrypted blob that must be
  processed server-side — is **whole-object in memory** today: a write materializes
  its input to a single binary before layers run, and a read pulls the full object
  back before layers unwrap it, so the practical ceiling is your available memory.

Streaming/chunked IO and multipart upload *through BlobIO* are roadmap items.
Encryption is whole-object for an extra reason: the bundled `aes-256-gcm` format
encrypts the object in a single authenticated pass. A chunked or streaming AEAD
(authenticated encryption with associated data) could be added later as a **new
format id** in the registry — existing blobs keep reading under their stamped
format, so it would be additive rather than a migration. See
[Encryption](encryption.md#algorithm-format).

## Can I serve byte ranges (e.g. video seeking / `Range` requests)?

It depends on how the blob is served:

- **Redirect to the service** — `AshStorage.Plug.Redirect` hands the client a
  URL for the underlying service (e.g. a presigned S3 URL). The client then talks
  to S3/Azure directly, and those backends honor `Range` natively. This is the
  path to use when you need range/seek behavior for **unlayered** blobs.
- **Proxy through the application** — `AshStorage.Plug.Proxy` reads the whole
  object through BlobIO and streams the response; it does not currently honor
  `Range`.
- **Layered or encrypted blobs** — cannot be ranged today regardless of the
  serving path. The bundled encryption format authenticates the whole object, so
  a byte range can't be decrypted in isolation; a future chunked format would be
  needed to change that.

## Can I use direct uploads (client-to-storage) with encryption?

No. Server-side envelope encryption requires the server to see the bytes before
they reach storage, so the encryption layer rejects direct-upload preparation.
When you need client-to-storage ergonomics for encrypted blobs, use an
application-owned staging workflow: the client uploads to a temporary location,
then a privileged server worker writes the canonical blob through BlobIO. See
[Encryption](encryption.md#direct-uploads) and
[Layers](layers.md#direct-uploads).

## Why won't my encrypted blob serve from a plain service URL?

By design. The encryption layer forces serving through a proxy (when
`proxy_base_url` is configured) or marks the blob not servable, because a direct
service URL would hand out raw ciphertext. Serve encrypted blobs through a
blob-aware proxy route that resolves the blob and reads via
`AshStorage.BlobIO.read/3`. See
[Encryption](encryption.md#serving-encrypted-blobs).

## Do signed proxy URLs authorize the current user?

No — they are **bearer capabilities**, not per-request authorization. A signed URL
carries an `expires` timestamp and an HMAC (hash-based message authentication
code) token, so it is tamper-proof and does
expire (default one hour; configurable via `expires_in`). But within its lifetime
anyone holding the URL can fetch the bytes — it does not re-check the actor at
fetch time. When access must be evaluated per request, point `proxy_base_url` at
an application route that authenticates and authorizes the actor before reading
through BlobIO. See [Layers](layers.md#serving) and [Encryption](encryption.md#serving-encrypted-blobs).

## Can I configure the same layer (e.g. encryption) more than once?

Yes — give each instance a distinct `metadata_key`. The metadata key is the
durable identity AshStorage persists to match a stored blob back to the layer
that can read it, so two instances of the same module must not share one. A layer
declares a default key, and a configured `metadata_key:` overrides it;
configurations whose layers collide on a key are rejected at compile time. See
[Layers](layers.md#configuration).

## Is there a maximum file size? What about multipart uploads?

For **server-side uploads** (bytes flow through the app), uploads are
single-`PUT` today, so the effective limit is what the backend accepts in one
request — and what fits in memory, per the streaming answer above. Services refuse
bodies past their threshold with a clear error rather than silently truncating or
splitting.

**Direct uploads** (client → storage) sidestep the application entirely, so the
in-memory ceiling doesn't apply — the limit is whatever the backend accepts.
These are available for unlayered blobs; a byte-transforming layer such as
encryption rejects direct uploads (see the direct-uploads question above).

Multipart/chunked upload *through BlobIO* is a roadmap item; see
[Checksum verification](checksum-verification.md) for how verification is intended
to extend to it.
