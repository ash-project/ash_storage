# Changelog

## [v0.1.0] - Unreleased

### Added

- Initial project setup
- Server-side checksum verification on upload via `Content-MD5` (S3, Azure)
- `AshStorage.Service.Context.put_expected_md5/2` and `:expected_md5` field
  for plumbing the expected MD5 to services on both upload and download
- `AshStorage.Service.Context.put_content_type/2` and `:content_type` field
  for plumbing the per-upload Content-Type to services. Used to set
  `Content-Type` headers on S3/Azure uploads and to thread per-variant types
  through `AshStorage.VariantGenerator`.
- Optional `c:AshStorage.Service.download_with_metadata/2` callback returning
  `%{body, content_type}` so consumers like `AshStorage.Plug.Proxy` can
  serve files with the upstream Content-Type instead of inferring from the
  opaque storage key. Implemented for S3, Azure, Disk, Mirror, and Test.

### Fixed

- S3 service now sets `Content-Type` on uploads from the blob's `content_type`.
  Previously, all S3-uploaded objects landed with `binary/octet-stream`
  regardless of the declared type, causing SVGs and (in some browsers) PNGs
  to fail to render when served directly from S3 or via a CDN.
- Azure Blob service now honours per-upload `Content-Type` passed to
  `Operations.attach/4`. Previously it only honoured an attachment-wide
  `:content_type` set in the storage DSL — per-call values were dropped.
- `AshStorage.Service.Mirror` now forwards the full upload context
  (including `expected_md5` and the new `content_type`) to every child
  service. The previous implementation rebuilt the child context from a
  hard-coded field list, silently dropping `expected_md5` and defeating
  checksum verification for any Mirror configuration.
- `AshStorage.Plug.Proxy` now serves files with the upstream service's
  Content-Type when available, falling back to `MIME.from_path/1` and the
  configured `:content_type_fallback` only when the service can't supply
  one. Previously the plug always inferred from the opaque storage key,
  so SVGs/PDFs/etc. served through the proxy were mis-typed even when the
  underlying bytes on S3/Azure had the right `Content-Type`.

### Changed

- Renamed `Context.put_upload_md5/2` to `put_expected_md5/2` and the
  `:upload_md5` field to `:expected_md5`. The field now serves both upload
  (sent as `Content-MD5`) and download verification (compared after fetch).
- `AshStorage.Service.S3.upload/3` now sends `Content-Type` and `Content-MD5`
  on the same PUT. Previously the MD5 helper replaced the headers list
  outright; it now merges, so callers can add their own headers without
  losing checksum verification.
- `AshStorage.Service.Test` now stores `content_type` alongside the bytes in
  ETS so tests can assert per-upload Content-Type round-trips. The ETS row
  shape changed from `{key, data}` to `{key, data, content_type}`; the
  service exposes a new `get_content_type/2` helper for assertions.
