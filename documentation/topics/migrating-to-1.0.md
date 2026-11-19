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
