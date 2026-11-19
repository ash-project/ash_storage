# Migrating to 1.0

This guide lists the changes on the way to 1.0 that need action, newest last.

## Serving plugs now download by default

What changed in `AshStorage.Plug.DiskServe` and `AshStorage.Plug.Proxy`:

- Every response carries `X-Content-Type-Options: nosniff`.
- `Content-Disposition` is always set. It is `attachment` unless the content type is in the mount's new `:inline` option, which defaults to `:none`.
- `?disposition=inline` has no effect; `?disposition=attachment` still forces a download.
- The `?filename=` value is encoded per RFC 6266, with quotes, backslashes, control characters and path separators removed.
- Only `GET` and `HEAD` are answered; anything else gets `405`. Answer CORS preflight requests before the mount.
- `:content_type_fallback` is now used, and `Plug.DiskServe` accepts it too.

Who this affects: links that open a file in the browser, and `<iframe>`, 
`<embed>` or `<object>` previews, now download the file. `Content-Disposition` 
does not change how `<img>` tags load files.

What to do: allow the types you want rendered on the mount.

```elixir
forward "/files", AshStorage.Plug.DiskServe, 
  root: "priv/storage", 
  inline: :images
```

Use `:documents` to add PDFs, or a list of content types. A `Plug.Proxy` mount 
can only tell the type of keys with an extension. See [Serving files](serving.md).

## Plug.Redirect now asks for downloads

What changed in `AshStorage.Plug.Redirect`:

- It takes the same `:inline` and `:content_type_fallback` options as the other serving plugs.
- It passes `disposition: "attachment"` to the service's `url/2` unless the key's content type is in `:inline`; for an allowed type it passes `content_type:` instead.
- Only `attachment` is forwarded from `?disposition=`; `?filename=` is cleaned before forwarding.
- Only `GET` and `HEAD` are answered; anything else gets `405`. The redirect carries `nosniff`.

The storage origin honours the disposition only where the service puts it into 
the URL: Azure SAS URLs do, S3 URLs do not yet. Set `inline:` on the mount for 
the types you want rendered. This only works for keys with a recognisable 
extension, or through `:content_type_fallback` on a mount that holds one kind 
of file; generated keys have no extension.
