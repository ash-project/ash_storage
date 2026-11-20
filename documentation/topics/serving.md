# Serving files

AshStorage ships plugs that serve stored files over HTTP. This guide covers the 
response headers they send and how to choose what may render in the browser.

## The plugs

- `AshStorage.Plug.DiskServe` serves files written by `AshStorage.Service.Disk`, using `send_file`.
- `AshStorage.Plug.Proxy` downloads a file from any service and sends it through your application.
- `AshStorage.Plug.Redirect` redirects to the service's own URL for the file.

They serve by storage key and do not look up the blob, so the blob's recorded 
`content_type` is not used. Its `filename` is used only where it reaches the 
plug in the request: `AshStorage.Service.Disk` adds it to its URLs as 
`?filename=`, which `Plug.DiskServe` uses for the download name and the content 
type.

## Keys from the request

The plugs take the storage key from the request path and answer `404`, without
calling the service, for a key that could reach outside the store: an empty
key, one with a control character, one that starts with `/` or `\`, and one
with a `..` segment. See [Storage keys](storage-keys.md).

## Defaults

`AshStorage.Plug.DiskServe` and `AshStorage.Plug.Proxy` apply these defaults to 
the file response:

- send `X-Content-Type-Options: nosniff` on every response, so the browser uses the declared type;
- send every file with `Content-Disposition: attachment` unless its content type is allowed to render inline (by default none is);
- answer only `GET` and `HEAD`, and `405 Method Not Allowed` otherwise. Answer CORS preflight requests before the mount if you need them.

`AshStorage.Plug.Redirect` sends `nosniff` and answers only `GET` and `HEAD` 
too, but the file is served by the storage service; see [Redirects](#redirects) 
for where the disposition is enforced.

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
> `image/svg+xml`, `text/html` and XML types are documents: they can run script 
> in the origin that serves them, with access to that origin's cookies and 
> pages. They are in no built-in set.
>
> List them only for content you fully control. A PDF opens in the browser's 
> own viewer and runs no script in your origin, which is why `:documents` 
> includes it.

## How the content type is chosen

- `AshStorage.Plug.DiskServe` uses the extension of the `filename` query
  parameter (`/<key>?filename=<filename>`, as `AshStorage.Service.Disk` builds
  URLs), then the key's extension.
- `AshStorage.Plug.Proxy` uses the key's extension.
- When neither gives a type, the mount's `:content_type_fallback` is used (default `"application/octet-stream"`).

Generated keys have no extension, so on a `Plug.Proxy` or `Plug.Redirect` mount 
`:inline` only takes effect for keys with a recognisable extension, or through 
`:content_type_fallback` on a mount that holds one kind of file.

On a `Plug.DiskServe` mount the `filename` parameter is chosen by whoever 
makes the request and is not covered by the URL signature. With an allowlist 
that only means choosing between a download and a type you declared safe. But 
if you list an active type such as `text/html` or `image/svg+xml` in `:inline` 
on a DiskServe mount, every file on it can be requested as that type.

## Request parameters

- `?disposition=attachment` forces a download. `AshStorage.Token.signed_url/4` adds it for `disposition: "attachment"`, and so does the Disk service when it signs URLs (has a `:secret`). Any other value is ignored.
- `?filename=` sets the download name. Quotes, backslashes, control characters and path separators are removed, and non-ASCII names are encoded per RFC 6266. On a `Plug.DiskServe` mount its extension also chooses the content type, before the key's; see [How the content type is chosen](#how-the-content-type-is-chosen). The Disk service adds it to every URL for which it knows the blob's filename.

Neither parameter is covered by the URL signature: a URL holder can change the 
name or force a download, but cannot make a response render inline.

## Redirects

`AshStorage.Plug.Redirect` takes the same `:inline` and 
`:content_type_fallback` options and decides the same way, from the key's 
extension. Because the browser then fetches the file from the storage service, 
the plug can only pass its decision to the service's `url/2`: 
`disposition: "attachment"` unless the type is allowed (or the request asks for 
`?disposition=attachment`), and `content_type:` with the allowed type 
otherwise. `?filename=` is passed on after cleaning.

Whether the storage origin honours this depends on the service:

- Azure with `presigned: true` puts both into the SAS URL (`rscd` and `rsct`), so it is enforced.
- A Disk URL leads to `AshStorage.Plug.DiskServe`. When the Disk service signs URLs (has a `:secret`), the `disposition=attachment` travels in the URL and forces a download there, so inline rendering needs `inline:` on both mounts. Without a `:secret` only the cleaned `?filename=` travels: the DiskServe mount uses it for the download name and guesses the content type from its extension, and its own `:inline` policy alone decides whether that type renders inline.
- S3 URLs (presigned or public), Azure URLs without presigning, the Test service and `AshStorage.Service.Mirror` do not carry the policy. The object is served with the headers stored on it, so an uploaded HTML or SVG file can render at the storage origin. That origin (the bucket's host, or a CDN domain in front of it) must then not be one your application trusts; otherwise use `AshStorage.Plug.Proxy` instead.

## Serve user content from a separate origin

The defaults stop a browser from running an uploaded file as a page of your 
application. They are one layer. Where you can, serve uploaded files from an 
origin that holds no session: a separate domain (for example 
`example-usercontent.com` beside `example.com`) is best, because a subdomain
is still the same site for cookies. A file that does get rendered there has nothing to steal. Mount the plug in an endpoint or router that only answers on 
that host, and point the service's `base_url` at it. The plugs do not check the 
request host.

Further headers, such as `Content-Security-Policy: sandbox`, 
`Cross-Origin-Resource-Policy` or a different `Cache-Control`, can be set by 
your own plug placed before the mount.

## One mount per policy

A mount's policy applies to every file reachable through it. Give content with 
different needs different mounts, and, for the Disk service, different roots.
