# Serving files

AshStorage ships plugs that serve stored files over HTTP. This guide covers the response headers
they send and how to choose what may render in the browser.

## The plugs

- `AshStorage.Plug.DiskServe` serves files written by `AshStorage.Service.Disk`, using `send_file`.
- `AshStorage.Plug.Proxy` downloads a file from any service and sends it through your application.
- `AshStorage.Plug.Redirect` redirects to the service's own URL for the file.

They serve by storage key and do not look up the blob, so the blob's recorded `content_type` and
`filename` are not used.

## Defaults

`AshStorage.Plug.DiskServe` and `AshStorage.Plug.Proxy` apply these defaults (`Plug.Redirect` does
not apply them yet):

- send `X-Content-Type-Options: nosniff` on every response, so the browser uses the declared type;
- send every file with `Content-Disposition: attachment` unless its content type is allowed to
  render inline (by default none is);
- answer only `GET` and `HEAD`, and `405 Method Not Allowed` otherwise. Answer CORS preflight
  requests before the mount if you need them.

## Allowing inline rendering

The `:inline` option on the mount lists the content types that may render in the browser:

```elixir
# Nothing renders inline (the default)
forward "/files", AshStorage.Plug.DiskServe, root: "priv/storage", inline: :none

# image/png, image/jpeg, image/gif and image/webp
forward "/files", AshStorage.Plug.DiskServe, root: "priv/storage", inline: :images

# The images above and application/pdf
forward "/files", AshStorage.Plug.DiskServe, root: "priv/storage", inline: :documents

# An explicit list
forward "/files", AshStorage.Plug.DiskServe, root: "priv/storage", inline: ["image/png", "text/plain"]
```

> #### SVG and PDF are not the same risk {: .warning}
>
> `image/svg+xml`, `text/html` and XML types are documents: they can run script in the origin
> that serves them, with access to that origin's cookies and pages. They are in no built-in set.
> List them only for content you fully control. A PDF opens in the browser's own viewer and runs
> no script in your origin, which is why `:documents` includes it.

## How the content type is chosen

- `AshStorage.Plug.DiskServe` uses the extension of the segment after the key
  (`/<key>/<filename>`, as `AshStorage.Service.Disk` builds URLs), then the key's extension.
- `AshStorage.Plug.Proxy` uses the key's extension.
- When neither gives a type, the mount's `:content_type_fallback` is used (default
  `"application/octet-stream"`).

Generated keys have no extension, so on a `Plug.Proxy` mount `:inline` only takes effect for keys
with a recognisable extension, or through `:content_type_fallback` on a mount that holds one kind
of file.

On a `Plug.DiskServe` mount the segment after the key is chosen by whoever makes the request and
is not covered by the URL signature. With an allowlist that only means choosing between a download
and a type you declared safe. But if you list an active type such as `text/html` or
`image/svg+xml` in `:inline` on a DiskServe mount, every file on it can be requested as that type.

## Request parameters

- `?disposition=attachment` forces a download. `AshStorage.Token.signed_url/4` adds it for
  `disposition: "attachment"`, and so does the Disk service when it signs URLs (has a `:secret`). Any other value is ignored.
- `?filename=` sets the download name. Quotes, backslashes, control characters and path
  separators are removed, and non-ASCII names are encoded per RFC 6266.

Neither parameter is covered by the URL signature: a URL holder can change the name or force a
download, but cannot make a response render inline.

## Serve user content from a separate origin

The defaults stop a browser from running an uploaded file as a page of your application. They are
one layer. Where you can, serve uploaded files from an origin that holds no session: a separate
domain (for example `example-usercontent.com` beside `example.com`) is best, because a subdomain
is still the same site for cookies. A file that does get rendered there has nothing to steal.
Mount the plug in an endpoint or router that only answers on that host, and point the service's
`base_url` at it. The plugs do not check the request host.

Further headers, such as `Content-Security-Policy: sandbox`, `Cross-Origin-Resource-Policy` or a
different `Cache-Control`, can be set by your own plug placed before the mount.

## One mount per policy

A mount's policy applies to every file reachable through it. Give content with different needs
different mounts, and, for the Disk service, different roots.
