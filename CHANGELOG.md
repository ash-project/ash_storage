# Changelog

## [v0.1.0] - Unreleased

### Added

- Initial project setup
- Server-side checksum verification on upload via `Content-MD5` (S3, Azure)
- `AshStorage.Service.Context.put_expected_md5/2` and `:expected_md5` field
  for plumbing the expected MD5 to services on both upload and download
- Optional `AshStorage.Service.stream_download/2` callback for chunked
  downloads, with `AshStorage.Operations.stream_download/2` and
  `stream_download_from_service/3` dispatching to it and falling back to
  `download/2` for services that don't implement it
- `AshStorage.Service.Disk` streams from the filesystem via `File.stream!/2`,
  with a `:chunk_size` service option (default `65_536`)
- `AshStorage.Service.S3` accepts a `:public_base_url` option, so public file
  URLs can point at a CDN or a custom domain instead of the S3 endpoint

### Changed

- Renamed `Context.put_upload_md5/2` to `put_expected_md5/2` and the
  `:upload_md5` field to `:expected_md5`. The field now serves both upload
  (sent as `Content-MD5`) and download verification (compared after fetch).

### Fixed

- `AshStorage.VariantGenerator` now sets `:content_type` and `:filename` on
  the `Context` it builds before calling a service's `upload/3`, matching
  what `attach/4` and `handle_file_argument.ex` already do for the primary
  upload. Previously both were `nil` for every variant upload, so any
  service that forwards them onto the underlying object — `AshStorage.Service.S3`
  setting the `Content-Type` header, for instance — silently lost them for
  variants specifically, uploading them as `binary/octet-stream` regardless
  of their real type.
- `AshStorage.Operations.prepare_direct_upload/3` now uses the attachment's
  `path` for the blob's key, as a server-side attach does. Previously it
  ignored `path` and fell back to the tenant prefix. Direct uploads have no
  parent action, so `path` is called with a `nil` changeset; use `ctx.actor`
  and `ctx.tenant` for a `path` that works in both flows.

### Removed

- `AshStorage.resolve_key_with_tenant/3`. `AshStorage.resolve_key/3` accepts
  a `nil` changeset and takes the tenant from the context instead.
