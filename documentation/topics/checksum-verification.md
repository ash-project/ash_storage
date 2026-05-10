# Checksum verification

AshStorage verifies file integrity using base64-encoded MD5 checksums. The
strategy differs by upload path and storage service. This page is the
single source of truth for what is verified, when, and what's still planned.

## Today's guarantees

### Server-side uploads (`Operations.attach`, `AttachFile`, variants)

The library computes the body's MD5 locally, sets it on the service context
as `:expected_md5`, and the service sends it as `Content-MD5` on PUT. If the
service-side hash disagrees, S3 returns `400 BadDigest` and Azure returns
`400 Md5Mismatch`. The upload aborts and no blob row is created.

For Azure, the same value is also sent as `x-ms-blob-content-md5`, which
*persists* the MD5 as a blob property — Azure echoes it on every subsequent
`Get Blob` / `HEAD Blob` response.

S3 needs no analogous header: the single-PUT ETag is the body's MD5,
already persisted server-side.

### Direct uploads (client → S3/Azure)

`AshStorage.Operations.prepare_direct_upload/3` creates a blob row with the
caller-provided expected `:checksum` (or empty if none provided). The
client uploads to the signed URL, then includes the `blob_id` in a normal
create/update action. `AshStorage.Changes.AttachBlob` performs an
auto-confirm step before linking:

1. Calls `Service.head(key, ctx)` to read integrity metadata without
   downloading the body.
2. Compares the service-reported MD5 against `blob.checksum`.
3. If `blob.checksum` was empty, populates it from the service value so
   future downloads can verify.
4. On mismatch, fails with `:checksum_mismatch`. No attachment is created.

### Downloads

`AshStorage.Operations.download/2` populates `:expected_md5` from
`blob.checksum` before invoking the service. The service hashes the
downloaded bytes and returns `{:error, :checksum_mismatch}` if they
disagree. Internal callers (analyzers, variant generation) use this
helper. External callers can call `Service.download/2` directly to skip
verification.

`AshStorage.Plug.Proxy` deliberately does NOT verify. The plug streams
bytes back to a client mid-response; a checksum-mismatch error after the
body has begun would surface as a 502 with a partial body, worse than
serving the bytes uncheckable.

## When `head/2` returns no usable checksum

Two real-world cases produce a `head/2` response with `content_md5: nil`:

- **S3 multipart objects.** The ETag has a `-N` suffix
  (`"abc123-2"`). S3's multipart ETag is `md5(concat(part_md5s)) + "-N"`,
  not the body's MD5. AttachBlob detects the suffix and reports
  `content_md5: nil`.
- **Azure blobs uploaded externally** without `x-ms-blob-content-md5`.
  Older AshStorage versions or third-party tools may not have set the
  property. Azure returns `Content-MD5` in the response only when the
  property was set at upload.

When `head/2` returns no MD5, AttachBlob falls back to a tier-3 decision:

- If `blob.checksum` is set (caller asked for verification),
  the attach fails with `:checksum_unverifiable_no_service_checksum`.
- If `blob.checksum` is empty, the attach succeeds and a
  `Logger.warning/1` is emitted so operators see the gap.

Services that don't implement the optional `head/2` callback at all skip
auto-confirmation entirely; AttachBlob logs a warning once per service
module so the gap is visible.

## Multipart / block-based uploads (planned)

Server-side verification today assumes a single PUT — the body fits in
one request and `Content-MD5` hashes the whole thing. S3 caps single-PUT
at 5 GB; Azure caps `Put Blob` at 5000 MiB and recommends keeping it
under 256 MiB. Larger files require multipart (S3) or block uploads
(Azure). This is on the roadmap; the verification strategy below is
locked in so the implementation can follow it directly.

### S3 multipart

- **Per-part `Content-MD5`** on every `UploadPart`. S3 verifies each part
  independently and rejects with `400 BadDigest` on any mismatch.
- **On `CompleteMultipartUpload`**, locally recompute the expected
  multipart ETag: `md5(concat(part_md5_raw_bytes)) + "-N"` where N is
  the part count. Compare to the response ETag. Or, alternatively, use
  S3 "additional checksums" (`x-amz-checksum-sha256` etc.) which survive
  multipart natively but are SHA-256, not MD5 — a separate column on the
  blob would be needed.

### Azure block uploads

- **Per-block `Content-MD5`** on every `Put Block`. Azure verifies each
  block.
- **On `Put Block List`**, set `x-ms-blob-content-md5` from the locally
  streamed full-body MD5. Azure persists this but does NOT verify it on
  the assembly call — verification is request-time only, per-block. The
  persisted property is for download-side verification later.

### Streaming hash

To avoid materializing the full body just to compute the whole-blob MD5,
multipart uploads will use `:crypto.hash_init(:md5)` and
`:crypto.hash_update/2` per chunk. The current `read_io/1` in
`AshStorage.Changes.Attach` and `AshStorage.Changes.HandleFileArgument`
materializes everything — this is the biggest refactor multipart will
require. The `upload/3` callback signature will need a streaming
variant, or a higher-level wrapper will sit in front of it.

### Switch-over threshold

Default proposal: switch to multipart at `byte_size > 256 MiB` with
`16 MiB` parts. Configurable per-service via service_opts.

### Backward compatibility

Services that don't implement the multipart variant should refuse files
exceeding the threshold with a clear error rather than silently splitting
or single-PUT-ing too-large bodies.

## Multipart-ETag surprise

If you're attaching pre-existing S3 blobs (uploaded before this library
got involved) and some are multipart, the auto-confirm logic above will
either fail or warn-and-attach depending on whether you provided an
expected checksum. This is by design — silently linking unverifiable
blobs would be worse. The code comment near `lib/ash_storage/service/s3.ex`
flags the single-PUT-only assumption explicitly.
