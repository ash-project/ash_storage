# Storage Keys

A storage key is the path an attachment's bytes live under in its service — the
`avatars/9f2c…` in a bucket, or the relative path under a disk root. AshStorage
computes the key once, when the blob is written, and **persists it on the blob
row**. It is never re-derived on read: a read looks the key up from the row.
That is why the default key can be a random string — nothing ever has to
reproduce it.

By default each blob gets an opaque random key from `AshStorage.generate_key/0`
(a 56-character lowercase hex token), prefixed with the tenant when one is
present (see [Tenancy](#tenancy) below). When you need more structure, the
`path` option on an attachment takes over key derivation entirely.

> #### Keys are exposed verbatim {: .warning}
>
> The proxy serves a blob by its key — the key *is* the URL path
> (`/proxy/storage/<key>`). Anything that ends up in a key shows up in
> user-facing URLs. Keep that in mind for every `path` you write and every
> tenant identifier you let into a key.

## Deriving the key with `path`

`path` is a 2-arity function receiving the service context and the changeset,
returning the key as a string:

```elixir
storage do
  has_one_attached :avatar do
    path fn _ctx, changeset ->
      "avatars/#{changeset.data.id}/#{AshStorage.generate_key()}"
    end
  end
end
```

The function has the whole changeset at hand — arguments, `changeset.data`,
`changeset.tenant`, `changeset.context` — so keys can be derived from whatever
the write knows. Append a fresh `AshStorage.generate_key/0` token when the rest
of the key is not already unique per blob: an attachment is bound to a record,
and a non-unique key means later writes overwrite earlier bytes.

### Keys are validated service-safe

Every key — derived or default — is validated before any bytes reach a service:
it must be non-empty, relative, and free of `..` traversal segments. A
misconfigured `path` fails the write with `{:error, {:unsafe_storage_key, key}}`
rather than escaping a disk-backed service's root or poisoning proxy URLs.

## Tenancy

When the write has a tenant and the attachment declares no `path`, the key is
automatically prefixed with the resolved tenant:

```text
<tenant>/<random>
```

The tenant is resolved once via `Ash.ToTenant.to_tenant/2`, so a struct tenant
becomes its canonical identifier. All of a tenant's blobs therefore sit under
one contiguous prefix, which keeps them isolated and lets listing or lifecycle
tooling operate per tenant.

> #### The resolved tenant is an internal identifier {: .warning}
>
> Because keys are exposed verbatim in URLs, the default prefix makes the
> resolved tenant identifier public. Whether that matters depends on what the
> identifier is. An opaque UUID — the common case — is non-enumerable and
> usually already visible elsewhere in your application's URLs and APIs, so
> the key adds little new exposure. Take care with the sharper cases: a
> sequential `org_id` under `:attribute` multitenancy (enumerable — neighbors
> can be guessed, customer counts inferred), or a `:context` schema name like
> `org_acme` (names the customer). If your tenant identifiers are sensitive,
> declare a `path` that names a value you have judged safe to expose — a slug,
> a public id — instead of relying on the default:
>
> ```elixir
> has_one_attached :avatar do
>   path fn _ctx, changeset ->
>     "#{changeset.data.org_slug}/#{AshStorage.generate_key()}"
>   end
> end
> ```

A `path` function replaces the default entirely — including the tenant prefix.
If you want the tenant in a derived key, put it there yourself (keeping the
tenant outermost preserves the contiguous per-tenant prefix).

## Variants

A variant blob inherits its source blob's key directory: the variant key is the
source key's directory portion plus a fresh random token. A tenant- or
path-scoped source therefore keeps its variants under the same prefix.

## Direct uploads

`AshStorage.Operations.prepare_direct_upload/3` creates the blob before any
parent changeset exists, so a `path` function — which needs the changeset —
cannot run. The key falls back to the tenant/random default and a warning is
logged, since blobs direct-uploaded for that attachment will not share the
derived layout. The tenant prefix still applies when a `:tenant` option is
passed.

## Derive from the record, not the actor

A key is computed once, at write time, and fixed forever. If a `path` derives
from the actor, two writes to the same record by different actors land under
different prefixes — fine when that is the intent, surprising when the prefix
was meant to group a tenant's blobs. For a stable layout, derive only from the
record and the tenant.

Authorization also never shapes a key: the protection against exposing a
sensitive value is not an actor check, it is that *you* chose what goes into a
public, persisted key.

## See also

  * [File arguments](file-arguments.md) and [Direct uploads](direct-uploads.md)
    — the write paths that derive a key.
