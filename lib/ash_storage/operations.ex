defmodule AshStorage.Operations do
  @moduledoc """
  Core operations for managing file attachments.

  These functions are convenience wrappers around Ash actions that are
  automatically added to the parent resource by the `AshStorage` extension.
  Each function calls the corresponding action on the parent resource.

  The underlying actions are:

  - `:attach_<name>` — upload file, create blob + attachment, run analyzers
  - `:detach_<name>` — remove attachment record(s) without deleting files
  - `:purge_<name>` — remove attachment + blob records and delete files
  """

  require Ash.Query
  require Logger

  alias AshStorage.AnalyzerMetadata
  alias AshStorage.BlobIO
  alias AshStorage.BlobIO.Support, as: BlobIOSupport
  alias AshStorage.Info
  alias AshStorage.Service.Context

  @doc """
  Attach a file to a record.

  Calls the `:attach_<name>` action on the parent resource, which uploads the
  file, creates a blob record, creates an attachment record, and runs analyzers.

  For `has_one_attached`, any existing attachment is replaced.
  For `has_many_attached`, the new attachment is appended.

  ## Options

  - `:filename` - (required) the original filename
  - `:content_type` - MIME type (default: `"application/octet-stream"`)
  - `:metadata` - additional metadata map
  - `:actor` - the actor performing the operation
  - `:tenant` - the tenant
  """
  def attach(record, attachment_name, io, opts \\ []) do
    {arg_opts, action_opts} = Keyword.split(opts, [:filename, :content_type, :metadata])

    args = %{
      io: io,
      filename: Keyword.fetch!(arg_opts, :filename),
      content_type: Keyword.get(arg_opts, :content_type, "application/octet-stream"),
      metadata: Keyword.get(arg_opts, :metadata, %{})
    }

    action_opts =
      Keyword.put(action_opts, :action, String.to_existing_atom("attach_#{attachment_name}"))

    case Ash.update(record, args, action_opts) do
      {:ok, record} ->
        {:ok,
         %{
           blob: record.__metadata__[:blob],
           attachment: record.__metadata__[:attachment],
           record: record
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Prepare a direct upload: create a blob record and return a signed upload target.

  The returned target is service-specific, such as an S3 presigned URL/form or an
  Azure Blob SAS URL. This stays as a standalone function since no parent record
  is involved yet.
  """
  def prepare_direct_upload(resource, attachment_name, opts \\ []) do
    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name) do
      {arg_opts, action_opts} =
        Keyword.split(opts, [:filename, :content_type, :byte_size, :checksum, :metadata])

      bctx =
        BlobIO.BlobContext.from_opts(resource, attachment_def,
          actor: Keyword.get(action_opts, :actor),
          tenant: Keyword.get(action_opts, :tenant),
          operation: :direct_upload
        )

      # A `path` function needs a changeset to derive the key from, and a direct
      # upload has none — `resolve_key_with_tenant/3` falls back to the
      # tenant/random default. Make that silent inconsistency visible: blobs
      # direct-uploaded for this attachment will not share the derived layout.
      if is_function(attachment_def.path) do
        Logger.warning(
          "attachment #{inspect(attachment_name)} on #{inspect(resource)} declares a `path` " <>
            "for storage keys, but direct uploads have no changeset to derive a key from. " <>
            "Falling back to the tenant/random default key."
        )
      end

      key =
        AshStorage.resolve_key_with_tenant(attachment_def, Keyword.get(opts, :tenant), resource)

      BlobIO.prepare_direct_upload(
        bctx,
        arg_opts
        |> Keyword.put(:key, key)
        |> Keyword.put(:ash_opts, action_opts)
      )
    end
  end

  @doc """
  Detach an attachment from a record without deleting the blob or file.

  Calls the `:detach_<name>` action on the parent resource.

  ## Options

  - `:blob_id` - (required for `has_many_attached`) which attachment to detach
  """
  def detach(record, attachment_name, opts \\ []) do
    {arg_opts, action_opts} = Keyword.split(opts, [:blob_id])

    args = %{blob_id: Keyword.get(arg_opts, :blob_id)}

    action_opts =
      Keyword.put(action_opts, :action, String.to_existing_atom("detach_#{attachment_name}"))

    case Ash.update(record, args, action_opts) do
      {:ok, record} ->
        {:ok, record.__metadata__[:detached_attachments] || []}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Detach all attachments for a given name from a record.

  Calls the `:detach_<name>` action with `all: true`.
  """
  def detach_all(record, attachment_name, opts \\ []) do
    args = %{all: true}

    action_opts =
      Keyword.put(opts, :action, String.to_existing_atom("detach_#{attachment_name}"))

    case Ash.update(record, args, action_opts) do
      {:ok, record} ->
        {:ok, record.__metadata__[:detached_attachments] || []}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Purge an attachment: destroy the attachment record, blob record, and file.

  Calls the `:purge_<name>` action on the parent resource.

  ## Options

  - `:blob_id` - (required for `has_many_attached` unless `:all` is true)
  - `:all` - purge all attachments for this name (default: `false`)
  - `:actor` - the actor performing the operation
  - `:tenant` - the tenant
  """
  def purge(record, attachment_name, opts \\ []) do
    {arg_opts, action_opts} = Keyword.split(opts, [:blob_id, :all])

    args = %{
      blob_id: Keyword.get(arg_opts, :blob_id),
      all: Keyword.get(arg_opts, :all, false)
    }

    action_opts =
      Keyword.put(action_opts, :action, String.to_existing_atom("purge_#{attachment_name}"))

    case Ash.update(record, args, action_opts) do
      {:ok, record} ->
        {:ok, record.__metadata__[:purged_attachments] || []}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Delete a file from a storage service.
  """
  def delete_from_service(service_mod, %Context{} = ctx, key) do
    service_mod.delete(key, ctx)
  end

  @doc """
  Download a blob's bytes from its storage service, verifying the body's MD5
  against `blob.checksum` when one is recorded.

  Internal callers (analyzers, variant generation) should use this instead of
  calling `Service.download/2` directly so verification stays consistent.
  External callers that don't want the integrity check can keep calling the
  service callback themselves.

  ## Options
  - `:actor` - the current actor
  - `:tenant` - the current tenant
  """
  def download(blob, opts \\ []) do
    bctx =
      BlobIO.BlobContext.new(
        blob: blob,
        actor: Keyword.get(opts, :actor),
        tenant: Keyword.get(opts, :tenant),
        operation: :download
      )

    BlobIO.read(blob, bctx)
  end

  @doc """
  Run a specific analyzer on a blob, downloading the file from storage if needed.

  This is intended for async analysis via AshOban jobs. It downloads the blob's file,
  runs the analyzer, and updates the blob's metadata and analyzer status.

  When `write_attributes` is configured on the analyzer, it finds the parent record
  via stored target info and writes the mapped values.
  """
  # sobelow_skip ["Traversal.FileModule"]
  def run_analyzer(blob, analyzer_module, opts \\ []) do
    analyzer_key = to_string(analyzer_module)
    blob_analyzers = blob.analyzers || %{}

    case Map.fetch(blob_analyzers, analyzer_key) do
      {:ok, analyzer_entry} ->
        tenant = Keyword.get(opts, :tenant) || analyzer_entry["tenant"]

        context_opts =
          opts
          |> Keyword.put(:tenant, tenant)
          |> Keyword.take([:actor, :tenant, :authorize?, :tracer])

        analyzer_opts = analyzer_entry["opts"] || %{}
        content_type = blob.content_type || "application/octet-stream"

        if analyzer_module.accept?(content_type) do
          with {:ok, bctx} <-
                 analyzer_blob_context(blob, analyzer_entry, analyzer_key, analyzer_module, opts),
               {:ok, data} <- BlobIO.read(blob, bctx) do
            path =
              Path.join(
                System.tmp_dir!(),
                "ash_storage_analyze_#{AshStorage.generate_key()}"
              )

            File.write!(path, data)

            try do
              keyword_opts =
                Enum.map(analyzer_opts, fn {k, v} -> {String.to_existing_atom(k), v} end)

              {status, metadata_to_merge} =
                case analyzer_module.analyze(path, keyword_opts) do
                  {:ok, result} -> {"complete", result}
                  {:error, _reason} -> {"error", %{}}
                end

              with {:ok, blob} <-
                     Ash.update(
                       blob,
                       %{
                         analyzer_key: analyzer_key,
                         status: status,
                         metadata_to_merge: metadata_to_merge
                       },
                       Keyword.merge(context_opts, action: :complete_analysis)
                     ) do
                if status == "complete" do
                  maybe_apply_oban_write_attributes(
                    analyzer_entry,
                    metadata_to_merge,
                    context_opts
                  )
                end

                {:ok, blob}
              end
            after
              File.rm(path)
            end
          end
        else
          Ash.update(
            blob,
            %{analyzer_key: analyzer_key, status: "skipped", metadata_to_merge: %{}},
            Keyword.merge(context_opts, action: :complete_analysis)
          )
        end

      :error ->
        {:error, :analyzer_not_configured}
    end
  end

  @doc """
  Attach multiple files to multiple records in bulk.

  Takes a list of `{record, attachment_name, io, opts}` tuples and processes them.
  Returns a list of results in the same order as the input.
  """
  def attach_many(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {{record, attachment_name, io, opts}, idx} ->
      {idx, attach(record, attachment_name, io, opts)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # -- Functions used by HandleDependentAttachments --

  @doc false
  def destroy_attachment_and_blob_records(record, attachment_name, opts \\ []) do
    resource = record.__struct__

    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
         {:ok, attachments} <- find_attachments(record, attachment_def, opts),
         {:ok, {service_mod, service_opts}} <- resolve_service(resource, attachment_def) do
      ctx = build_context(service_opts, resource, attachment_def, opts)

      Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, keys_acc} ->
        blob = att.blob

        with {:ok, _} <- Ash.destroy(att, action: :destroy, return_destroyed?: true),
             {:ok, _} <- Ash.destroy(blob, action: :destroy, return_destroyed?: true) do
          {:cont, {:ok, [{service_mod, ctx, blob.key} | keys_acc]}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  @doc false
  def mark_attachments_for_purge(record, attachment_name, opts \\ []) do
    resource = record.__struct__

    with {:ok, attachment_def} <- Info.attachment(resource, attachment_name),
         {:ok, attachments} <- find_attachments(record, attachment_def, opts) do
      Enum.reduce_while(attachments, {:ok, []}, fn att, {:ok, acc} ->
        blob = att.blob

        with {:ok, _} <- Ash.destroy(att, action: :destroy, return_destroyed?: true),
             {:ok, blob} <-
               Ash.update(
                 blob,
                 %{pending_purge: true},
                 action: :mark_for_purge,
                 return_record?: true
               ) do
          {:cont, {:ok, [blob | acc]}}
        else
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  # -- Private helpers --

  defp analyzer_blob_context(blob, analyzer_entry, analyzer_key, analyzer_module, opts) do
    case AnalyzerMetadata.fetch_source(analyzer_entry) do
      {:ok, resource, attachment_def} ->
        {:ok, build_analyzer_blob_context(blob, analyzer_module, opts, resource, attachment_def)}

      :missing ->
        if BlobIOSupport.layer_metadata_from_blob(blob) == [] do
          {:ok, build_analyzer_blob_context(blob, analyzer_module, opts)}
        else
          {:error, {:missing_blob_io_context, :analyzer, analyzer_key}}
        end

      {:error, reason} ->
        {:error, {:invalid_blob_io_context, :analyzer, analyzer_key, reason}}
    end
  end

  defp build_analyzer_blob_context(
         blob,
         analyzer_module,
         opts,
         resource \\ nil,
         attachment \\ nil
       ) do
    BlobIO.BlobContext.new(
      resource: resource,
      attachment: attachment,
      blob: blob,
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      operation: :analyze,
      analyzer: analyzer_module
    )
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp maybe_apply_oban_write_attributes(analyzer_entry, metadata_to_merge, context_opts) do
    write_attributes = analyzer_entry["write_attributes"]
    write_target = analyzer_entry["write_target"]

    if write_attributes && write_target && map_size(write_attributes) > 0 do
      resource = String.to_existing_atom(write_target["resource"])
      record_id = write_target["id"]
      tenant = context_opts[:tenant] || write_target["tenant"]

      context_opts =
        context_opts
        |> Keyword.put(:tenant, tenant)
        |> Keyword.take([:actor, :tenant, :authorize?, :tracer])

      attrs =
        Enum.reduce(write_attributes, %{}, fn {result_key, attr_name}, acc ->
          case Map.fetch(metadata_to_merge, result_key) do
            {:ok, value} -> Map.put(acc, String.to_existing_atom(attr_name), value)
            :error -> acc
          end
        end)

      if map_size(attrs) > 0 do
        case Ash.get(resource, record_id, context_opts) do
          {:ok, record} ->
            record
            |> Ash.Changeset.for_update(:update, %{})
            |> Ash.Changeset.force_change_attributes(attrs)
            |> Ash.update(context_opts)

          _ ->
            :ok
        end
      end
    end
  end

  defp build_context(service_opts, resource, attachment_def, opts) do
    Context.new(service_opts,
      resource: resource,
      attachment: attachment_def,
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant)
    )
  end

  defp resolve_service(resource, attachment_def) do
    case Info.service_for_attachment(resource, attachment_def) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :no_service_configured}
    end
  end

  # sobelow_skip ["DOS.BinToAtom"]
  defp find_attachments(record, attachment_def, context_opts) do
    resource = record.__struct__
    attachment_resource = Info.storage_attachment_resource!(resource)
    record_id = Map.get(record, :id) |> to_string()

    belongs_to_resources =
      Spark.Dsl.Extension.get_entities(attachment_resource, [:attachment])

    parent_rel =
      Enum.find(belongs_to_resources, fn bt ->
        bt.resource == resource
      end)

    filter =
      if parent_rel do
        [{:name, to_string(attachment_def.name)}, {:"#{parent_rel.name}_id", record_id}]
      else
        [
          name: to_string(attachment_def.name),
          record_type: to_string(resource),
          record_id: record_id
        ]
      end

    attachment_resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.load(:blob)
    |> Ash.read(Keyword.take(context_opts, [:actor, :tenant, :authorize?, :tracer]))
  end
end
