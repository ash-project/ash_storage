# Serving Blobs

AshStorage serves a stored blob's bytes to a client in one of two ways, and the
choice governs where the bytes flow, what can render them, and what security
properties apply. This guide covers both, the plugs that implement them, signed
URLs and access, and how to serve untrusted (user-uploaded) content safely.

## Two serving paths

**Direct from the provider (`serve: :service_url`, the default).** The URL you
hand a client is a presigned provider URL (an S3/MinIO/Azure GET), and the
browser fetches the bytes **straight from the bucket**. `AshStorage.Plug.Redirect`
turns a request into a `302` to that presigned URL. The application never touches
the bytes.

**Through the application (proxy).** The bytes pass through your app —
`AshStorage.Plug.Proxy` resolves the blob by key, reads it through `BlobIO`
(running any layers, e.g. decrypting an encrypted blob), and streams the result.

The default URL calculations (`…_url` on an attachment) emit a `:service_url`,
so unencrypted blobs serve **direct from the provider by default**. Encryption
forces proxy serving (a presigned URL would hand out ciphertext), and you can opt
any blob into proxy serving with `serve: :proxy` and a `:proxy_base_url`.

| Serve via… | Use when |
|---|---|
| direct (`:service_url`) | public or non-sensitive blobs; large downloads (no app bandwidth); `Range`/seek needed |
| proxy | encrypted/layered blobs; content that must be access-checked in the app; content whose **disposition** must be controlled (see below) |

## Where the bytes render — origin and trust

This distinction decides how serious a stored-XSS risk is, so it's worth stating
plainly:

- **Direct serving renders in the *provider's* origin** (e.g.
  `bucket.s3.amazonaws.com`). Script in an HTML blob served there executes in an
  origin isolated from your application — it cannot read your app's cookies,
  session, or DOM. Lower severity **unless** you front the bucket on your own
  domain (a custom domain or path-mapped CDN), which puts it back on your origin.
- **Proxy serving renders in the *application's* origin.** Script in an HTML blob
  served through the proxy executes same-origin with your app — full stored-XSS.

So the disposition controls below matter most on the **proxy** path, and any
content you serve *inline* from your own origin must be treated as untrusted.

## The serving plugs

- **`AshStorage.Plug.Proxy`** — blob-aware. Configured with `resource` +
  `attachment` (or a lower-level `blob_resource`/`service`), it looks up the blob,
  reads through `BlobIO`, and sets response headers. This is the path for
  encrypted content, access-controlled content, and controlled disposition.
- **`AshStorage.Plug.DiskServe`** — serves raw files from a disk root by path.
  It does **not** resolve a blob record, so it applies only route-level policy
  (it can't key anything off a specific blob or attachment). `send_file/5` streams
  from disk without buffering.
- **`AshStorage.Plug.Redirect`** — presigns a provider URL and returns a `302`.
  The egress mechanism for direct serving.

## Signed URLs and access

A proxy route serves by key, and a signed URL is a **bearer capability** — anyone
holding it gets the bytes for the URL's lifetime; it is not per-request
authentication. Configure a route's posture with `:access`:

- `access: :public` — serve without a signature (acknowledge public serving).
- `access: {:signed, secret: "…"}` — require a valid signed URL.

A **blob-aware or encryption-aware** route that declares neither raises at
`init/1` by default (`:proxy_access_requirement` defaults to `:require`) — you
must choose a posture rather than serve sensitive content publicly by accident.

Two further proxy knobs harden the bearer model:

- `:actor_assign` threads the request's authenticated actor onto the
  `BlobContext`, so a per-actor key manager can authorize the read. The proxy
  does **not** authenticate — wire your auth pipeline ahead of it and point
  `:actor_assign` at the assign it populates.
- `:max_lifetime_seconds` refuses a signed URL whose *remaining* lifetime exceeds
  a cap — a defense-in-depth lid on over-long tokens.

Signed responses are sent `cache-control: no-store, private` so bearer-gated
bytes aren't cached by shared intermediaries.

## Content disposition and inline rendering

Serving is governed by a content-type allowlist. Raster images render inline by
default (`inline: :images`); any type outside the policy — `text/html`,
`image/svg+xml`, `application/pdf`, unknown — is served
`Content-Disposition: attachment`, and `X-Content-Type-Options: nosniff` is
always set. Together these stop a caller-influenced `content_type` from executing
in the serving origin: a user-uploaded `text/html` downloads rather than
rendering, and a blob mislabeled as an image but containing HTML can't be
MIME-sniffed into an active type.

Widen the inline set — e.g. to preview a PDF in an `<iframe>` — or narrow it,
with `:inline`:

```elixir
forward "/documents", AshStorage.Plug.Proxy,
  resource: MyApp.Document,
  attachment: :file,
  access: {:signed, secret: doc_secret()},
  inline: :documents
```

`:inline` accepts:

  * **`:images`** — raster images (`image/png`, `image/jpeg`, `image/gif`,
    `image/webp`). The default.
  * **`:documents`** — `:images` plus `application/pdf`.
  * **`:none`** — nothing inline; every response is `attachment`.
  * **an explicit list** — e.g. `["image/png", "application/pdf"]`.

A response is served `inline` only when its resolved content-type is in the
policy; everything else is `attachment`. The request can narrow toward safety but
never widen it — `?disposition=attachment` forces a download even of an
otherwise-inline PDF (a "Download" control), while `?disposition=inline` is
ignored for a type outside the policy. `DiskServe` takes the same `:inline` opt,
so the two plugs are symmetric.

> #### SVG and PDF are not the same risk {: .warning}
>
> `image/svg+xml` is in **no** built-in set. A declared SVG served inline is an
> active document — its embedded `<script>` executes in the serving origin, and
> `nosniff` cannot prevent it (the type *is* the dangerous one). A PDF, by
> contrast, renders in the browser's sandboxed viewer, isolated from the page —
> so `application/pdf` is a safe inline opt-in but SVG is not. Only add
> `image/svg+xml` to an explicit list if you fully control or sanitize the
> content.

### Disposition applies only to app-served paths

The `:inline` allowlist and `nosniff` are set by the serving plugs, so they apply
only when the bytes pass **through your application** — proxy and disk serving.
On the **direct (`:service_url`) path**, the browser fetches straight from the
provider and these controls never run: the object is served under its own stored
`Content-Type` with whatever `Content-Disposition` it carries (none by default,
i.e. inline) and no `nosniff`. Bytes there render in the provider's origin (see
above), so the same-origin XSS risk is lower — but active content (HTML/SVG) can
still reach sibling objects in the same bucket origin, and a bucket fronted on
your app's domain is same-origin again. **Serve untrusted content through the
proxy**, where these controls apply. (Setting a provider-side default
disposition on the bucket, or configuring `response-content-disposition` on the
presign, is an app/provider-level option outside these plugs.)

### A mount's policy applies to every blob it can serve

Serving is key-addressed: the `:inline` policy applies to **any** blob requested
through that mount, not only the blobs "meant" for it. A permissive mount is a
capability over its whole reachable key space. Two consequences:

  * A **blob-aware mount** (configured for a `resource`+`attachment`) already
    self-scopes to that attachment's blobs — this is the common, safe case, and
    it's where putting `inline:` on the mount effectively gives you
    per-attachment policy.
  * A **generic key-only mount** over a shared bucket does not — a permissive
    policy there applies to everything in the bucket. Before widening such a
    mount's allowlist, narrow what it can reach: a dedicated service/bucket/prefix
    holding only content safe to render, and/or tighter access.

### Several policies

Build **one mount per distinct policy tier**, not the powerset — attachments that
share a policy share a mount. Since blob-aware mounts are already configured per
`resource`+`attachment`, you typically have one mount per attachment already;
give each the `inline:` it needs. Keep the default path conservative and route to
a wider mount only where a real preview need exists. URL generation selects which
mount a given blob's URL points at — a small helper (`document_url/1` vs
`avatar_url/1`) is the whole pattern.

## Range / partial requests

Byte-range requests (video seeking, resumable downloads) depend on the path:

- **Direct serving** — the provider handles `Range` natively; the client talks to
  the bucket, which supports ranged GETs.
- **Proxy serving** — the current proxy reads and sends the whole object, so it
  does not serve partial content. Ranged reads of a layered/encrypted blob require
  a streaming/chunked format that isn't built yet.

If you need `Range` for large media, serve it direct (unencrypted); if it must be
encrypted, whole-object fetch is the current ceiling.

## Serving untrusted, user-uploaded content

Uploads whose `content_type` and bytes are attacker-controlled are the case these
controls exist for. The safe recipe:

1. **Serve through the proxy**, not a direct provider URL — so disposition and
   `nosniff` apply, and (for encrypted blobs) the bytes are access-mediated. This
   is what encryption already forces.
2. **Opt inline in by content-type, never blanket.** Use `inline: :images` or
   `:documents` (or a curated list) so scriptable types (`text/html`,
   `image/svg+xml`) always download. Don't add SVG.
3. **Keep untrusted content off permissive mounts.** If one mount needs a wide
   policy, make sure its key space holds only content you trust to render.
4. If you serve inline in an `<iframe>`, consider the iframe `sandbox` attribute
   and a `Content-Security-Policy` on your app side as defense in depth — the
   library sets no framing headers, so embedding is up to you.

## See also

  * [Encryption](encryption.md) — encrypted blobs force proxy serving; the same
    "serve untrusted content through the proxy" principle, generalized.
  * [Storage keys](storage-keys.md) — the key appears verbatim in serving URLs.
  * [Direct uploads](direct-uploads.md) — the write-side counterpart to direct
    serving.
