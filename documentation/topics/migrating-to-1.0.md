# Migrating to 1.0

This guide lists the changes on the way to 1.0 that need action, newest last.

## Serving plugs download by default

What changed in `AshStorage.Plug.DiskServe` and `AshStorage.Plug.Proxy`:

- Every response carries `X-Content-Type-Options: nosniff`.
- `Content-Disposition` is always set. It is `attachment` unless the content type is in the
  mount's new `:inline` option, which defaults to `:none`.
- `?disposition=inline` has no effect; `?disposition=attachment` still forces a download.
- The `?filename=` value is encoded per RFC 6266, with quotes, backslashes, control characters and
  path separators removed.
- Only `GET` and `HEAD` are answered; anything else gets `405`. Answer CORS preflight requests
  before the mount.
- `:content_type_fallback` is now used, and `Plug.DiskServe` accepts it too.

Who notices: links that open a file in the browser, and `<iframe>`, `<embed>` or `<object>`
previews, now download the file. `Content-Disposition` does not change how `<img>` tags load
files.

What to do: allow the types you want rendered on the mount.

```elixir
forward "/files", AshStorage.Plug.DiskServe, root: "priv/storage", inline: :images
```

Use `:documents` to add PDFs, or a list of content types. A `Plug.Proxy` mount can only tell the
type of keys with an extension. See [Serving files](serving.md).
