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

## The Disk service writes owner-only files

What changed: `AshStorage.Service.Disk` gives every file it writes the mode
`0600`, and every directory it creates the mode `0700`. Before, both followed
the umask of the process, which usually meant `0644` and `0755`. Directories
that already exist keep their mode, and files that are already stored are not
touched. A failed upload now returns `{:error, reason}` when a directory
cannot be created, where it raised before.

Who this affects: setups where another operating system user reads the files,
for example a web server that serves the storage root itself, or a backup job
that runs under its own account.

What to do: nothing, when only the application reads the files (through
`AshStorage.Plug.DiskServe` or `AshStorage.Plug.Proxy`). Otherwise set
`owner_only: false` on the service and control the modes with the umask as
before:

```elixir
service {AshStorage.Service.Disk, root: "priv/storage", base_url: "/files", owner_only: false}
```

To tighten the files that are already stored, run `chmod -R go-rwx` on the
storage root once.

## Disk URLs no longer end with the filename

What changed: the `url/2` function of `AshStorage.Service.Disk` built
`<base_url>/<key>/<filename>` when it knew the blob's filename. It now builds
`<base_url>/<key>?filename=<filename>`, and `AshStorage.Plug.DiskServe` takes
the whole request path below the mount as the key, so keys that contain `/`,
such as keys with a tenant prefix or from a `path` function, can be served. A
URL of the old shape gets `404`. The URL calculations now pass the blob's
filename and content type as the context's `:filename` and `:content_type`, and
no longer set the undocumented `:original_filename` service option, which the
Disk service no longer reads. The plug also resolves keys with the Disk service's
rules, so a symbolic link under the root that leads outside it, or that has an
absolute target, is no longer served and gets `404`.

Who this affects: applications that serve files with `AshStorage.Plug.DiskServe`
and stored Disk URLs somewhere (rendered pages, emails, a cache); code that
passed `:original_filename` to `Disk.url/2`; custom services that read
`service_opts[:original_filename]` in `url/2`; and storage roots that contain
symbolic links.

What to do: generate stored URLs again from the URL calculations or
`Disk.url/2` instead of keeping them. Pass the filename on the context instead
of `:original_filename`:

```elixir
ctx = AshStorage.Service.Context.new(service_opts, filename: blob.filename)
AshStorage.Service.Disk.url(blob.key, ctx)
```

In a custom service, read `ctx.filename` in `url/2` instead of
`service_opts[:original_filename]`; `ctx.content_type` holds the blob's
content type.

Replace a symbolic link that leads outside the root, or that has an absolute
target, with a relative link that stays inside the root, or with a copy of the
file. See [Keys in requests](storage-keys.md#keys-in-requests).

## Signed URLs use a new token

What changed: a signed URL carries one `token` parameter,
`?token=v1.<payload>.<signature>`, in place of `?token=…&expires=…`. The token
holds the storage key, the issue time, the expiry and, when they are set, the
disposition, the filename and the content type, and it is bound to the
`download` purpose. `AshStorage.Plug.Proxy`, `AshStorage.Plug.Redirect` and
`AshStorage.Plug.DiskServe` accept only this format. On a signed mount they
take the disposition, the filename and the content type from the token and
ignore the `disposition` and `filename` query parameters.
`AshStorage.Token.sign(secret, key, expires_at)` is removed; `sign/3` now takes
a map of claims, and `verify/3` checks a token.

Who this affects: every application with a `:secret` on a serving plug or on
the Disk service. Signed URLs issued before the upgrade get `403`; by default
they last an hour. During a rolling deploy, instances on the old and the new
version reject each other's URLs. Code that called `Token.sign/3` with a
secret, a key and an expiry, or that added `disposition` or `filename` to a
signed URL by hand, also has to change.

What to do: deploy all instances together, or accept that signed URLs fail
for up to their lifetime. Build URLs with `AshStorage.Token.signed_url/4` and
pass the response parameters to it instead of appending them:

```elixir
AshStorage.Token.signed_url("/files/#{key}", secret, key,
  disposition: "attachment",
  filename: "report.pdf",
  content_type: "application/pdf"
)
```

## Signed Disk URLs carry the blob's content type

What changed: when the Disk service has a `:secret`, the URLs from the URL
calculations sign the blob's recorded content type, and
`AshStorage.Plug.DiskServe` uses it before the extension of the filename or the
key. Before, only those extensions counted, so a file with a generated key and
no extension in its filename never rendered inline.

Who this affects: signed `AshStorage.Plug.DiskServe` mounts with `:inline`.
Files whose recorded content type is in the mount's `:inline` list now render
inline, also when their key and filename have no extension.

What to do: nothing, if that is what the `:inline` list is meant to allow. The
recorded type is what the uploader declared, and `nosniff` keeps the browser
from reading the file as anything else; the mount's `:inline` list still
decides what renders. Narrow the list if it allows more than you want to
render.

## Purging removes variants, keeps shared blobs and deletes files after the commit

What changed: attaching a file to a `has_one_attached` that already has one
removes the old file the same way `purge_<name>` does.

- `purge_<name>`, a replacement, the `dependent` option and the `:purge_blob`
  action remove a blob's variants before the blob. On Postgres a blob with a
  variant could not be purged or replaced at all; on data layers without
  foreign keys the variant rows and files were left behind.
- `purge_<name>`, a replacement and the `dependent` option remove a blob only
  when no other attachment row references it. The `:purge_blob` action does
  not check: it removes the blob it is given. The check counts every row in
  the caller's tenant, also rows the caller's read policies would hide.
- `purge_<name>` and a replacement delete the files after the transaction
  commits, as the `dependent` option already did. A failure later in the same
  action no longer leaves rows that point at deleted files. Inside a
  transaction the caller opened, files are still deleted before it commits.
- A file that cannot be deleted no longer fails `purge_<name>` or a
  replacement: the rows are gone, and a warning names the service and the
  key.

Who this affects: code that relied on `purge_<name>` or a replacement failing
when the service could not delete the file. It now succeeds and logs a
warning, and the object stays in the store. Code that expects the file to be
gone when the action returns inside its own transaction is not affected: there
the file is still deleted before the action returns.

What to do: nothing, for most applications. Watch the logs for the warning if
you need to know about objects left behind. An application that attaches one
blob to several records should know that purging one of them keeps the file.

## File arguments run the whole attachment declaration

What changed: the change that attaches a file from an action argument runs
the same steps as the generated `attach_<name>` action. A file attached
through a file argument now gets the attachment's eager variants, has its `generate: :oban` variants
recorded and enqueued, and sets `pending_analyzers` for `analyze: :oban`
analyzers, so their job runs instead of being cancelled. An existing
`has_one_attached` file is replaced on create actions too, not only on
updates.

Who this affects: attachments with variants or `analyze: :oban` analyzers that
are written through a file argument. They start getting them; blobs attached
before the upgrade are not back-filled. Upsert actions with a file argument:
each call used to add an attachment row next to the existing one, and now
replaces it. Duplicate rows left by earlier upserts stay until the next
replacement, which removes them.

What to do: nothing. To back-fill variants or background analysis for files
attached before the upgrade, attach them again, or generate the variants and
run the analyzers yourself.

## Direct uploads run analyzers and variants

What changed: attaching a directly uploaded blob through
`AshStorage.Changes.AttachBlob` runs the attachment's analyzers and variants,
as the other ways of attaching a file do. Eager analyzers run in the action
and write their `write_attributes` with the record, eager variants are
generated, and `analyze: :oban` analyzers and `generate: :oban` variants are
recorded and enqueued. Before, a directly uploaded file got none of them.

The eager steps need the file's bytes, which the server never had, so the
action downloads the object from the service: once for all eager analyzers,
when one of them accepts the content type, and once more for each eager
variant, inside the action and its transaction.

The blob is also confirmed before the record is written, not after: an unknown
blob id or a checksum mismatch now fails the action before anything is saved.
A blob that is a variant of another blob, or that is marked for purge, is
refused with `:blob_not_found`.

Who this affects: every attachment that is written through a direct upload and
declares analyzers or variants. Analyzers are eager unless declared otherwise,
so an attachment with an analyzer and no `analyze: :oban` now downloads every
directly uploaded file during the action. Code that expected a record to be
created even when its blob id was wrong, on a data layer without transactions,
no longer gets that record.

What to do: review each attachment used with direct uploads. For large files
declare `analyze: :oban` on its analyzers and `generate: :oban` on its
variants, or leave variants on demand.

## Host resources need a single primary key attribute

What changed: attachments find and write their host record by the resource's
primary key attribute, whatever its name. Before, they always used `:id`. A
resource that declares attachments and does not have exactly one primary key
attribute no longer compiles, with a `Spark.Error.DslError` in its `storage`
section:

```text
MyApp.Post declares attachments, and AshStorage identifies the record an
attachment belongs to by a single primary key attribute. The resource's
primary key is made of :id, :org.
```

Who this affects:

- Resources with attachments and a composite primary key. If the key included
  `:id`, records that shared an `:id` also shared their attachments, without
  any error. Those resources now fail to compile. That includes a key whose
  `:id` is unique on its own, such as a partitioned table keyed
  `(id, org_id)`, which worked before.
- Resources whose single primary key has another name, such as
  `attribute :slug, :string, primary_key?: true`. With a polymorphic
  attachment resource they now work; before, they failed to compile with an
  error about the missing `:id` field. With `belongs_to_resource` on the
  attachment resource they still do not: the relationship it generates expects
  `:id` on the host.

What to do: give a resource with attachments a single primary key attribute,
for example a `uuid_primary_key :id`, and turn the rest of a composite key into
an identity. When `:id` is unique on its own, as in the partitioned table
above, declare only `:id` as the Ash primary key (`primary_key?: true`) and
leave the database's key as it is. If you generate migrations from your
resources, check the next generated migration before running it: the
database's key must stay as it is. Attachments written before for a composite key that included
`:id` are found by that `:id` value, so check whether records shared them.

## `attach_file/2` and `attach_blob/2` are imported into resources

What changed: the `AshStorage` extension imports
`AshStorage.Changes.Builtins.attach_file/2` and
`AshStorage.Changes.Builtins.attach_blob/2` into every resource that uses it,
so actions can write `change attach_file(:cover_image)` and
`change attach_blob(:cover_image, argument: :cover_image_blob_id)`.

The `change` entries of each create and update action that attach from an
argument are also checked when the resource compiles. An attachment the
resource does not declare, or an argument the action does not have, is
reported as a warning naming the action. If it is left in, an action with a
wrong attachment fails when it is given a file or blob id and attaches nothing
when it is not; an action without the argument never attaches anything. With
`mix compile --warnings-as-errors` the warning fails the build. Changes in
the resource's `changes` section are not checked.

Who this affects: a resource module that defines its own function named
`attach_file` or `attach_blob` with one or two arguments and calls it inside
the module. That call now clashes with the import and the module does not
compile. Code interface functions with those names are not affected. An action
whose change tuple names a wrong attachment or argument, or an argument that
is only set programmatically and not declared on the action, now gets the
warning.

What to do: rename such a local function. Of the module tuples, only
`{AshStorage.Changes.AttachBlob, argument: ..., attachment: ...}` keeps
working; the two for file arguments are removed, see the next section.

## `attach_file/2` replaces `HandleFileArgument` and `AttachFile`

What changed: `AshStorage.Changes.HandleFileArgument` and
`AshStorage.Changes.AttachFile` are removed. A resource that still names one of
them in a `change` compiles with a warning that names the action and the
replacement, and the action raises an `UndefinedFunctionError`, wrapped in an
Ash error, every time it is called, whether a file is passed or not. Search
your code for both module names.
`change attach_file(:cover_image)` is the one way to attach a file from an
action argument; see `AshStorage.Changes.Builtins.attach_file/2`.

For `HandleFileArgument`, replace the tuple and nothing else:

```elixir
# before
change {AshStorage.Changes.HandleFileArgument,
        argument: :cover_image, attachment: :cover_image}

# after
change attach_file(:cover_image)
```

For `AttachFile`, replace the tuple the same way, and read on. `AttachFile`
attached the file by running the generated `attach_<name>` update action on
the record once the action had saved it. `attach_file/2` attaches inside the
action it is used in, and no second action runs. So these stop applying to a
file argument:

1. policies that match the attach action, by its name or by the action type
   `:update`;
2. changes and validations the resource declares for update actions;
3. notifiers and pub-sub messages for that update;
4. the update timestamp: `updated_at` was bumped right after a create;
5. extensions that record updates, such as audit logs.

Also:

- the result now carries `<name>_blob` and `<name>_attachment` metadata;
- an update action with `attach_file/2` needs `require_atomic? false`;
- eager analyzers run before the record is written, and their
  `write_attributes` are part of that write, so a failing upload fails the
  action before anything is saved.

Who this affects: every resource that uses either module.

What to do: replace the tuple with `attach_file/2`. If you relied on one of
the five points above, there are two ways out.

- Move the rule to the action that takes the file: a policy on that action,
  or a change with `where: [present(:cover_image)]`.
- Keep the second action: call `AshStorage.Operations.attach/4` from an
  `after_action` hook. It runs the generated `attach_<name>` action with
  everything it carries:

```elixir
create :create do
  accept [:title]
  argument :cover_image, :file, allow_nil?: true

  change fn changeset, context ->
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      case Ash.Changeset.get_argument(changeset, :cover_image) do
        nil ->
          {:ok, record}

        file ->
          filename =
            case Ash.Type.File.filename(file) do
              {:ok, filename} -> filename
              _ -> "upload"
            end

          content_type =
            case Ash.Type.File.content_type(file) do
              {:ok, content_type} -> content_type
              _ -> "application/octet-stream"
            end

          opts =
            Ash.Context.to_opts(context, filename: filename, content_type: content_type)

          with {:ok, %{record: record}} <-
                 AshStorage.Operations.attach(record, :cover_image, file, opts) do
            {:ok, record}
          end
      end
    end)
  end
end
```

The hook returns the record from the attach result, so the analyzers'
`write_attributes` are on what the caller gets back. The attach runs inside
the outer action's transaction, so a file it replaces is deleted before that
transaction commits.

## `scope:` on `AshStorage.Operations`

What changed: the functions of `AshStorage.Operations` that take options
accept `scope:`, a value implementing `Ash.Scope.ToOpts`, as Ash's 
functions do. It supplies the actor, tenant, `authorize?`, tracer and context;
options given explicitly win over the scope's. `attach/4`, `detach/3`,
`detach_all/3` and `purge/3` already passed it to the host action;
`prepare_direct_upload/3`, `download/2`, `stream_download/2` and
`run_analyzer/3` now read it too. A context given explicitly is merged with
the scope's, its keys winning, as Ash does.

AshStorage now requires Ash 3.5.27 or later. `Ash.Scope` exists from 3.5.13,
and from 3.5.27 Ash's handling of `scope:` merges the scope's context
with the caller's, which the functions that hand `scope:` on to Ash rely on.

Who this affects: applications on Ash 3.5.0 to 3.5.26, which have to update
Ash. Nothing else changes for code that works today.

What to do: update Ash to 3.5.27 or later if you are on an older 3.5. Pass
`scope:` instead of `actor:` and `tenant:` if you prefer.

## Policies on blob and attachment resources

What changed: the calls AshStorage makes for itself still carry the caller's
actor, tenant and `authorize?`, and now also the private context
`%{ash_storage?: true}`. They are its calls to blob and attachment rows:
storing, analyzing, linking, replacing and purging a file, generating
variants, and the background jobs. Two more carry it:

- an analyzer job that writes its `write_attributes` reads and updates the
  host record as a marked call;
- a read that generates a variant on demand, for its URL, creates that
  variant's blob as a marked call, for whoever reads the host record.

The marker is never on the caller's call to a host action, such as
`attach_<name>`. The new policy check `AshStorage.Checks.AshStorageInteraction`
matches it, so a blob or attachment resource can allow the library's calls
with a bypass and deny everything else:

```elixir
policies do
  bypass AshStorage.Checks.AshStorageInteraction do
    authorize_if always()
  end
end
```

Who this affects: nobody who does not use the check. The marker is in the
private context, which a policy only sees when it asks for it, and Ash does not
pass private context on to nested calls.

What to do: nothing. To lock the blob and attachment resources down to the
library, add the bypass. A host resource that adds it allows the analyzer
job's write-back too.

## `prepare_direct_upload/3` creates its blob as one of the library's calls

What changed: `AshStorage.Operations.prepare_direct_upload/3` creates the blob
with the caller's actor, tenant, `authorize?`, tracer and context (directly or
through `scope:`) and the private marker above, like the library's other
calls. Before, it passed the caller's other options to the blob's `:create`
action as they were.

Who this affects: applications whose blob resource has the
`AshStorage.Checks.AshStorageInteraction` bypass. With it, the blob
resource's `:create` policies no longer decide who may start a direct upload.
Without the bypass nothing changes. Other Ash options, such as `load:` or
`domain:`, are no longer passed to the blob's create action.

What to do: authorize the caller before you call
`prepare_direct_upload/3`. The function has no host record and no host action
to do it.
