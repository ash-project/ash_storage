# Storage keys

A storage key is the name a file has inside its storage service: the path under
the Disk service's root, or the object name in a bucket or container. AshStorage
chooses the key once, when a file is attached or a direct upload is prepared,
and stores it on the blob record. It is never worked out again. Every later
read, URL and delete uses the stored key.

## How a key is chosen

- By default the key is `AshStorage.generate_key/0`, a random 56-character hex string.
- When the action has a tenant, the key is `<tenant>/<generated key>`. See [Tenant prefixes](#tenant-prefixes).
- When the attachment has a `path` function, the key is what that function returns, and the tenant is not added.
- A variant is stored next to its source: its key is the source's key with the last segment replaced by a new generated key.

## The rules

A key is made of segments separated by `/`, and a segment may contain only
ASCII letters, digits, `.`, `_` and `-`, and must not end with `.`.

`AshStorage.Key.validate/1` checks every key after it has been chosen, before
anything is uploaded and before a blob record is created. A key must:

- be between 1 and 1024 bytes long;
- contain only `A-Z`, `a-z`, `0-9`, `.`, `_`, `-` and the separator `/`;
- be relative, with no `/` at the start or the end;
- have no empty segment (`a//b`), no `.` segment and no `..` segment.

These characters need no encoding in a URL, a file name or an object name, so a
key means the same to every service and plug. Everything else is rejected:
spaces, `~`, `%`, `?`, `#`, `:`, `@`, `+`, backslashes, control characters and
every non-ASCII character. A key that breaks a rule is rejected. It is never
rewritten into a valid one.

A rejected key fails the operation with the term
`{:invalid_storage_key, reason, key}`, for example
`{:invalid_storage_key, :parent_segment, "../etc/passwd"}`.
`AshStorage.Operations.prepare_direct_upload/3` returns it in an `:error`
tuple. An attach action returns an Ash error whose message contains it. Nothing
has been stored at that point.

The 1024 bytes are the limit of S3 and of Azure Blob Storage. A service's own
`:prefix` option is added in front of the key and counts towards the service's
limit. The Disk service is also bound by the file system, usually 255 bytes for
each segment.

The keys of files that are already stored are not checked again. A file whose
key has other characters is read, served and purged as before; whether a URL
for such a key works depends on the service and the client, as it always did.
No new file can be stored under such a key.

## Choosing keys with `path`

```elixir
has_one_attached :avatar do
  path fn _ctx, _changeset ->
    "avatars/#{AshStorage.generate_key()}"
  end
end
```

The function receives the service context (with `ctx.actor`, `ctx.tenant` and
`ctx.resource`) and the changeset of the action, and returns the key.

- **Make it unique.** Two files stored under one key overwrite each other. End
  the key with `AshStorage.generate_key/0` unless the rest is already unique
  for each file.
- **Build it from values you control.** Ids, slugs and
  `AshStorage.generate_key/0` are in the allowed set. A value that comes from a
  user, such as a file name, usually is not, and it is not cleaned for you. See
  [Values from user input](#values-from-user-input).
- **A key is fixed once it is written.** Changing the function later affects
  new files only.
- **Test it.** `AshStorage.Key.validate/1` returns `:ok` or the error for any
  value, so a test can check what your function returns.

### Direct uploads pass no changeset

`AshStorage.Operations.prepare_direct_upload/3` chooses the key before any
action runs, so it calls the `path` function with `nil` in place of the
changeset. A function that reads `changeset.data` or `changeset.tenant` raises
there. For an attachment that is used both ways, build the key from the
context, which is filled in both cases:

```elixir
path fn ctx, _changeset -> "#{ctx.tenant}/covers/#{AshStorage.generate_key()}" end
```

or give the function a clause for `nil`:

```elixir
path fn
  ctx, nil -> "incoming/#{ctx.tenant}/#{AshStorage.generate_key()}"
  _ctx, changeset -> "posts/#{changeset.data.id}/#{AshStorage.generate_key()}"
end
```

Both examples assume a tenant. An empty value in an interpolation leaves an
empty segment or a leading `/`, and such a key is rejected.

### Values from user input

A file name such as `Résumé (final).pdf` is not a valid segment, and it is
rejected, not rewritten. The simplest answer is to leave the file name out of
the key: the blob record keeps it in `filename`.

If you want it in the key, make it safe yourself, and put the generated key
into the same segment, so that the segment is unique and never empty, `.` or
`..`:

```elixir
safe = filename |> String.replace(~r/[^A-Za-z0-9._-]+/, "-") |> String.trim_trailing(".")
"uploads/#{AshStorage.generate_key()}-#{safe}"
```

This turns `Résumé (final).pdf` into `R-sum-final-.pdf`. Different names can
give the same result, which is why the generated key stays in.

## Tenant prefixes

Without a `path` function, the tenant becomes the first segment of the key. It
is converted with `Ash.ToTenant` and `to_string/1`, and the result has to be one
valid segment. UUIDs, integers and names such as `org_42` are.

A tenant with any other character is rejected with
`{:invalid_storage_key, {:tenant, reason}, tenant}`: `"acme/eu"` (the reason is
`:separator`), `"org:123"`, an email address or a name with a space (the reason
is `:invalid_character`). It is not split, encoded or cleaned. For such tenants,
give the attachment a `path` function that maps the tenant to a valid segment.
An id or a slug that the tenant already has is best. Otherwise encode it, so
that two tenants never share a prefix:

```elixir
has_one_attached :avatar do
  path fn ctx, _changeset ->
    tenant = ctx.tenant |> Ash.ToTenant.to_tenant(ctx.resource) |> to_string()
    "#{Base.url_encode64(tenant, padding: false)}/#{AshStorage.generate_key()}"
  end
end
```

`"org:123"` becomes `b3JnOjEyMw`. Encoding does not hide the tenant. A tenant
whose only problem is `/` can also be used as it is, which keeps the `/` as a
directory level: `"#{ctx.tenant}/#{AshStorage.generate_key()}"`.

## Keys are not secrets

A key appears in URLs (the serving plugs address a file by its key), in logs
and in error terms. With the default layout the tenant is part of it.

- Do not put anything into a key that the people who receive the URL must not
  see: an email address, an internal customer name, a sequential id that lets
  others be guessed.
- Do not rely on a key being hard to guess to protect a file. Use signed URLs
  (the `:secret` option of the plugs and of the Disk service) or your own
  authorization in front of the mount.

## Keys in requests

The serving plugs take the key from the request path. They answer `404`, without
calling the service, for a key that is empty, contains a control character,
starts with `/` or `\`, or has a `..` segment. They do not apply the other
rules, so files stored before the rules existed can still be served.
`AshStorage.Plug.Proxy` and `AshStorage.Plug.Redirect` then hand the key to the
service, which keeps its own checks; the Disk service refuses any key that would
resolve outside its root. `AshStorage.Plug.DiskServe` does not go through the
Disk service: it reads the file named by the first path segment from its own
`:root`, and follows symbolic links found there.
