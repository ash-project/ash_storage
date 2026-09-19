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
- `AshStorage.Service.GoogleDrive`, a Google Workspace Shared Drive backend
  built on `req` + `goth`, adapted from a production Drive integration.
  Implements `stream_download/2` via Req's `into: :self`; note its chunks
  must be consumed in the calling process. Does not implement
  `direct_upload/2`

### Changed

- Renamed `Context.put_upload_md5/2` to `put_expected_md5/2` and the
  `:upload_md5` field to `:expected_md5`. The field now serves both upload
  (sent as `Content-MD5`) and download verification (compared after fetch).
