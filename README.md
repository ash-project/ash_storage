# AshStorage

[![CI](https://github.com/ash-project/ash_storage/actions/workflows/elixir.yml/badge.svg)](https://github.com/ash-project/ash_storage/actions/workflows/elixir.yml)
[![Hex version](https://img.shields.io/hexpm/v/ash_storage.svg)](https://hex.pm/packages/ash_storage)

An [Ash](https://hexdocs.pm/ash) extension for file storage, attachments, and variants.

AshStorage provides a consistent interface for uploading, storing, and serving files across multiple storage backends (local disk, S3, GCS, Azure). It includes support for file analysis, image variants, previews, and direct uploads.

## Installation

Add `ash_storage` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_storage, "~> 0.1.0"}
  ]
end
```

## Documentation

- [HexDocs](https://hexdocs.pm/ash_storage)
- [Ash Framework](https://hexdocs.pm/ash)
