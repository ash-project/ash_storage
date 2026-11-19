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

## Polymorphic attachments are matched on `record_type`

This affects attachment resources with no `belongs_to_resource`, where a row
names its owner with `record_type` and `record_id`.

What changed: the relationship that `has_one_attached` and `has_many_attached`
generate on a host resource now filters on `record_type` as well as on the
attachment name. Before, it matched on `record_id` and the name only, so two
resources that shared an attachment resource could load each other's files when
their records had equal ids. The `<name>_url`, `<name>_urls` and variant URL
calculations load through that relationship and change with it.

Who this affects: a row is now loaded only when its `record_type` is the value
of `AshStorage.Info.record_type/1` for the host resource, which is the module
name as a string, for example `"Elixir.MyApp.Post"`. Rows stored under another
value no longer load:

- rows written before the host resource's module was renamed or moved;
- rows your own code created with a different `record_type`.

Attaching, detaching, purging and the `dependent` option already matched on
`record_type`, so they were already skipping such rows.

What to do: list the stored values, and rewrite the ones that are not the
module name of a current host resource. Use your attachment table's name.

```sql
SELECT record_type, count(*) FROM storage_attachments GROUP BY record_type;

UPDATE storage_attachments
SET record_type = 'Elixir.MyApp.Blog.Post'
WHERE record_type = 'Elixir.MyApp.Post';
```

A record that was given a new file after the rename has a row under each value.
After the update both rows belong to it again, so for a `has_one_attached`
remove the one you do not want first.

## `AshStorage.Transformer` and `Operations.attach_many/1` are removed

`AshStorage.Transformer` was unused, so it was removed until a clear use case
for it is established. To produce a variant, implement 
`AshStorage.Variant`: its `transform/3` takes the same arguments and returns 
`{:ok, metadata}` instead of `:ok`, and it has an `accept?/1` callback for the 
content types it handles.

`AshStorage.Operations.attach_many/1` was removed because its implementation
did not actually match the stated semantics, i.e. it simply called `attach/4`
on each item individually, rather than actually optimizing for a bulk import.
We may add this API back once proper bulk import semantics can be established.
For migrating, simply replace calls of `attach_many/1` with the following,
which is equivalent:

```elixir
results =
  Enum.map(items, fn {record, name, io, opts} ->
    AshStorage.Operations.attach(record, name, io, opts)
  end)
```

## Storage keys are now validated, with more restrictive rules than before

What changed: the key of every new file is checked by `AshStorage.Key.validate/1`
before anything is uploaded and before a blob record is created. A key is made
of segments separated by `/`, and a segment may contain only ASCII letters,
digits, `.`, `_` and `-`, and must not end with `.`. A key must be 1 to 1024
bytes long, must not start or end with `/`, and must have no empty, `.` or `..`
segment. A key that breaks a rule is rejected, never rewritten. See
[Storage keys](storage-keys.md).

Who this affects:

- An attachment whose `path` function returns such a key. Attaching, file
  arguments and `AshStorage.Operations.prepare_direct_upload/3` now fail with
  `{:invalid_storage_key, reason, key}` instead of storing the file. Typical
  causes are a file name or another value from a user in the key (a
  space, a non-ASCII letter, a backslash), a leading `/`, or an empty
  interpolated value that leaves `//` or a trailing `/` in the key.
- Variants of a file whose stored key breaks a rule before its last segment,
  for example `org:123/3f9a` or `/3f9a`. A variant's key is the source's
  key with the last segment replaced, so it is rejected too and the variant is
  not generated. A source key that breaks a rule only in its last segment
  still gets variants.
- Callers of `AshStorage.resolve_key/3` and `AshStorage.resolve_variant_key/1`,
  which now return `{:ok, key}` or `{:error, error}` instead of the key.

Files that are already stored keep their keys. The keys are not checked again,
and the files can still be read, served and purged as before.

What to do: make the `path` function return a valid key. Leave values that come
from a user out of it, or make them safe first; see
[Values from user input](storage-keys.md#values-from-user-input).

## A tenant must work as one key segment

This affects attachments without a `path` function on resources that use
multitenancy.

What changed: the tenant is the first segment of the key, `<tenant>/<key>`.
Before, it was joined to the key as it was, so the tenant `"acme/eu"` produced
two segments and `".."` pointed outside the store. Now a tenant that contains
`/` or any character other than ASCII letters, digits, `.`, `_` and `-`, or that
is `.` or `..` or ends with `.`, fails the operation with
`{:invalid_storage_key, {:tenant, reason}, tenant}`. It is not encoded. UUIDs,
integers and names such as `org_42` are fine; `org:123`, an email address or a
name with a space are not.

What to do: add a `path` function that builds the key from the tenant. For
tenants that contain `/` and are otherwise valid, this one keeps the old layout:

```elixir
has_one_attached :avatar do
  path fn ctx, _changeset -> "#{ctx.tenant}/#{AshStorage.generate_key()}" end
end
```

`ctx.tenant` is the tenant as it was given to the action. If that is a struct,
convert it first with `Ash.ToTenant.to_tenant(ctx.tenant, ctx.resource)`.

For tenants with other characters the old layout cannot be kept. Map the tenant
to a valid segment, as [Tenant prefixes](storage-keys.md#tenant-prefixes)
shows. New files then go under the new prefix. Files that are already stored
keep their keys and are still found, because the key is on the blob record.
