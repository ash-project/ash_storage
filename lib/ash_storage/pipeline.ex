defmodule AshStorage.Pipeline do
  @moduledoc false
  # The steps of attaching, replacing, detaching and purging a file, shared by
  # every way of doing so. Each step takes an explicit `Pipeline.Scope`.

  require Ash.Query

  alias AshStorage.Info
  alias AshStorage.Pipeline.{Analysis, Owner, Purge, Scope, Source, Target}
  alias AshStorage.Service.Context

  @doc "Resolves an attachment of `resource` by name."
  @spec resolve(Ash.Resource.t(), atom()) ::
          {:ok, Target.t()} | {:error, {:unknown_attachment, atom()}}
  def resolve(resource, attachment_name) do
    case Info.attachment(resource, attachment_name) do
      {:ok, attachment} ->
        service =
          case Info.service_for_attachment(resource, attachment) do
            {:ok, service} -> service
            :error -> nil
          end

        attachment_resource = Info.storage_attachment_resource!(resource)

        {:ok,
         %Target{
           resource: resource,
           attachment: attachment,
           service: service,
           blob_resource: Info.storage_blob_resource!(resource),
           attachment_resource: attachment_resource,
           owner: Owner.new(resource, attachment_resource)
         }}

      :error ->
        {:error, {:unknown_attachment, attachment_name}}
    end
  end

  @doc """
  Uploads `source` under the target's attachment and creates its blob row.
  The key comes from the attachment's `path`, called with `changeset`; an
  invalid key fails before anything is uploaded.
  """
  @spec store(Source.t(), Target.t(), Scope.t(), Ash.Changeset.t() | nil) ::
          {:ok, struct(), :stored} | {:error, term()}
  def store(%Source{} = source, %Target{} = target, %Scope{} = scope, changeset) do
    with {:ok, {service_mod, ctx}} <- Target.service_context(target, scope),
         {:ok, key} <- AshStorage.resolve_key(target.attachment, ctx, changeset),
         # The service sees what the bytes are, so that it can record it on the
         # object (the S3 service sends the content type as `Content-Type`)
         ctx =
           ctx
           |> Context.put_expected_md5(source.checksum)
           |> Context.put_blob_metadata(
             content_type: source.content_type,
             filename: source.filename
           ),
         {:ok, extra_attrs} <- normalize_upload(service_mod.upload(key, source.data, ctx)),
         attrs =
           Map.merge(
             %{
               key: key,
               filename: source.filename,
               content_type: source.content_type,
               byte_size: source.byte_size,
               checksum: source.checksum,
               service_name: service_mod,
               service_opts: Target.persistable_service_opts(service_mod, ctx.service_opts),
               metadata: source.metadata
             },
             extra_attrs
           ),
         {:ok, blob} <-
           Ash.create(target.blob_resource, attrs, Scope.to_opts(scope, action: :create)) do
      {:ok, blob, :stored}
    end
  end

  @doc """
  Records the target's analyzers on `blob` and runs the eager ones on
  `source`. Returns the host attributes their `write_attributes` map to, for
  the host action to write. `record` is the host record as the action sees
  it before its write, so on a create its key is not known yet.
  """
  @spec analyze(struct(), Source.t(), Target.t(), Scope.t(), struct()) ::
          {:ok, struct(), map()} | {:error, term()}
  def analyze(blob, %Source{} = source, %Target{} = target, %Scope{} = scope, record) do
    with {:ok, blob} <- Analysis.init(blob, target, scope, record) do
      Analysis.run_eager(blob, source, target, scope)
    end
  end

  defp normalize_upload(:ok), do: {:ok, %{}}
  defp normalize_upload({:ok, attrs}) when is_map(attrs), do: {:ok, attrs}
  defp normalize_upload({:error, _} = error), do: error

  @doc """
  The attachment rows of `record` under the target's attachment, with their
  blobs loaded. `filters` narrows them further, for example `blob_id: id`.
  """
  @spec attachments(struct(), Target.t(), Scope.t(), keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def attachments(record, %Target{} = target, %Scope{} = scope, filters \\ []) do
    filter = Owner.keys(target, record) ++ filters

    target.attachment_resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.load(:blob)
    |> Ash.read(Scope.to_opts(scope))
  end

  @doc """
  The attachments a detach or purge acts on: all of a `has_one`, and of a
  `has_many` the one holding `blob_id`, or all of them with `all?`.
  """
  @spec select([struct()], Target.t(), term(), boolean()) ::
          {:ok, [struct()]} | {:error, :blob_id_required_for_has_many}
  def select(attachments, %Target{attachment: %{type: :one}}, _blob_id, _all?),
    do: {:ok, attachments}

  def select(attachments, %Target{attachment: %{type: :many}}, _blob_id, true),
    do: {:ok, attachments}

  def select(attachments, %Target{attachment: %{type: :many}}, blob_id, _all?)
      when not is_nil(blob_id),
      do: {:ok, Enum.filter(attachments, &(&1.blob_id == blob_id))}

  def select(_attachments, %Target{attachment: %{type: :many}}, nil, _all?),
    do: {:error, :blob_id_required_for_has_many}

  @doc """
  Removes attachment rows, and with them each blob no other row references.

  - `:detach` removes the attachment rows only.
  - `:purge` also destroys each blob's variant rows, then the blob row, and
    returns a deletion per destroyed row. The files are not touched.
  - `:mark` sets `pending_purge` on each blob instead and enqueues the
    `:purge_blob` job for it.
  """
  @spec unlink([struct()], :detach | :purge | :mark, Target.t(), Scope.t()) ::
          {:ok, %{attachments: [struct()], deletions: [Purge.deletion()], marked: [struct()]}}
          | {:error, term()}
  def unlink(attachments, mode, %Target{} = target, %Scope{} = scope)
      when mode in [:detach, :purge, :mark] do
    result = %{attachments: [], deletions: [], marked: []}

    attachments
    |> Enum.reduce_while({:ok, result}, fn attachment, {:ok, acc} ->
      case unlink_one(attachment, mode, target, scope) do
        {:ok, destroyed, deletions, marked} ->
          {:cont,
           {:ok,
            %{
              attachments: [destroyed | acc.attachments],
              deletions: acc.deletions ++ deletions,
              marked: acc.marked ++ marked
            }}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, %{marked: [_ | _] = marked}} = ok ->
        AshOban.run_triggers(marked, :purge_blob)
        ok

      other ->
        other
    end
  end

  defp unlink_one(attachment, mode, target, scope) do
    destroy_opts = Scope.to_opts(scope, action: :destroy, return_destroyed?: true)

    with {:ok, destroyed} <- Ash.destroy(attachment, destroy_opts) do
      if mode == :detach do
        {:ok, destroyed, [], []}
      else
        remove_blob(destroyed, attachment.blob, mode, target, scope)
      end
    end
  end

  # The blob row can already be gone, for example after a manual delete; then
  # there is nothing left to remove.
  defp remove_blob(destroyed, nil, _mode, _target, _scope), do: {:ok, destroyed, [], []}

  defp remove_blob(destroyed, blob, mode, target, scope) do
    case Purge.referenced?(blob, target, scope) do
      {:ok, true} ->
        {:ok, destroyed, [], []}

      {:ok, false} when mode == :purge ->
        with {:ok, deletions} <- Purge.destroy_blob(blob, scope, target) do
          {:ok, destroyed, deletions, []}
        end

      {:ok, false} ->
        with {:ok, marked} <- Purge.mark(blob, scope) do
          {:ok, destroyed, [], [marked]}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Creates the attachment row that links `blob` to `record`."
  @spec insert_attachment(struct(), struct(), Target.t(), Scope.t()) ::
          {:ok, struct()} | {:error, term()}
  def insert_attachment(record, blob, %Target{} = target, %Scope{} = scope) do
    params = Map.new(Owner.keys(target, record) ++ [blob_id: blob.id])

    Ash.create(target.attachment_resource, params, Scope.to_opts(scope, action: :create))
  end
end
