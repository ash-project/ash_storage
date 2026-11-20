# Serving files

AshStorage ships plugs that serve stored files over HTTP. This guide covers the 
response headers they send and how to choose what may render in the browser.

## The plugs

- `AshStorage.Plug.DiskServe` serves files written by `AshStorage.Service.Disk`, using `send_file`.
- `AshStorage.Plug.Proxy` downloads a file from any service and sends it through your application.
- `AshStorage.Plug.Redirect` redirects to the service's own URL for the file.

They serve by storage key and do not look up the blob. The blob's recorded 
`content_type` and `filename` are used only where they reach the plug in the 
request: `AshStorage.Service.Disk` puts them in the URLs it builds, in the 
signed token when it has a `:secret` (see [Signed URLs](#signed-urls)) and the 
filename as `?filename=` otherwise.

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

The plugs use the first of these that gives a type:

| Mount | Sources, in order |
|---|---|
| signed, any plug | the token's content type, the extension of the token's filename, the key's extension |
| unsigned `Plug.DiskServe` | the extension of `?filename=`, the key's extension |
| unsigned `Plug.Proxy` or `Plug.Redirect` | the key's extension |

When none gives a type, the mount's `:content_type_fallback` is used (default
`"application/octet-stream"`). A malformed or generic declared type, such as
`application/octet-stream`, is skipped.

On a signed mount the issuer chooses these values: `AshStorage.Service.Disk`
signs the blob's recorded content type and filename, so `:inline` also works
for generated keys, which have no extension. The recorded type is what the
uploader declared; `nosniff` keeps the browser from reading the file as
anything else, and the mount's `:inline` list still decides what renders.

On an unsigned mount, generated keys have no extension, so on a `Plug.Proxy` or
`Plug.Redirect` mount `:inline` only takes effect for keys with a recognisable
extension, or through `:content_type_fallback` on a mount that holds one kind
of file.

On an unsigned `Plug.DiskServe` mount the `filename` parameter is chosen by
whoever makes the request. With an allowlist that only means choosing between a
download and a type you declared safe. But if you list an active type such as
`text/html` or `image/svg+xml` in `:inline` on such a mount, every file on it
can be requested as that type. Sign the URLs of such a mount.

## Request parameters

On an unsigned mount:

- `?disposition=attachment` forces a download. Any other value is ignored.
- `?filename=` sets the download name, and on `Plug.DiskServe` its extension
  chooses the content type (see above). The Disk service adds it to every
  unsigned URL for which it knows the blob's filename.

A requester can change these, but cannot make a response render inline. On a
signed mount both parameters are ignored: the token carries the disposition and
the filename. In both cases quotes, backslashes, control characters and path
separators are removed from the filename, and non-ASCII names are encoded per
RFC 6266.

## Signed URLs

A mount with a `:secret` serves only requests with a valid `token` parameter,
as `AshStorage.Token.signed_url/4` and the Disk service (with the same
`:secret`) build them:

    /files/covers/3f9a?token=v1.<payload>.<signature>

The token is signed with HMAC-SHA256 and covers the storage key, the expiry
and, when the issuer sets them, the disposition, the filename and the content
type. The mount answers `403 Forbidden`, and tells nothing more, when the token
is missing, malformed, signed with another secret, made for another purpose or
another key, or expired, or when any part of it was changed. A key that could
reach outside the store gets `404` before the token is checked.

- The mount and the service that signs its URLs must have the same secret.
- A token is not bound to a mount: it is valid on every mount that shares the
  secret. Give mounts with different policies different secrets.
- The token is a bearer credential in the query string. Anyone who has the URL
  can use it until it expires, and query strings end up in logs and browser
  history. Keep `expires_in` short.

## Redirects

`AshStorage.Plug.Redirect` takes the same `:inline` and 
`:content_type_fallback` options and decides the same way; see
[How the content type is chosen](#how-the-content-type-is-chosen). Because the
browser then fetches the file from the storage service, the plug can only pass
its decision to the service's `url/2`: `disposition: "attachment"` unless the
type is allowed (or the token or, on an unsigned mount, the request asks for a
download), and `content_type:` with the allowed type otherwise. The filename,
from the token or from `?filename=`, is passed on after cleaning.

Whether the storage origin honours this depends on the service:

- Azure with `presigned: true` puts both into the SAS URL (`rscd` and `rsct`), so it is enforced.
- A Disk URL leads to `AshStorage.Plug.DiskServe`. When the Disk service signs URLs (has a `:secret`), the disposition, the filename and the allowed content type travel in the token, and a forced download holds there, so inline rendering needs `inline:` on both mounts. Without a `:secret` only the cleaned `?filename=` travels: the DiskServe mount uses it for the download name and guesses the content type from its extension, and its own `:inline` policy alone decides whether that type renders inline.
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
