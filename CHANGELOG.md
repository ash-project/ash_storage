# Changelog

## [v0.1.0] - Unreleased

### Added

- Initial project setup
- Added `AshStorage.Service.AzureBlob` for Azure Blob Storage uploads, downloads, URLs, and direct uploads.
- Added Azurite-backed live integration coverage for `AshStorage.Service.AzureBlob`.
- Documented Azure SAS/CORS requirements and avoided persisting literal Azure credentials on blob records.

### Changed

- `AshStorage.Service.S3` now treats an empty string `:prefix` the same as `nil` (no prefix applied), matching `AshStorage.Service.AzureBlob`.
