# Changelog

## [v0.1.0] - Unreleased

### Added

- Initial project setup
- Server-side checksum verification on upload via `Content-MD5` (S3, Azure)
- `AshStorage.Service.Context.put_expected_md5/2` and `:expected_md5` field
  for plumbing the expected MD5 to services on both upload and download

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
