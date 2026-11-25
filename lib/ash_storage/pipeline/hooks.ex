defmodule AshStorage.Pipeline.Hooks do
  @moduledoc false
  # Which step runs in which changeset hook. What `before_action` found
  # travels to `after_action` in the changeset's context. Files that a
  # replacement or a removal makes obsolete travel from `after_action` to
  # `after_transaction` on the record's metadata: an `after_action` hook
  # cannot change the changeset, and on failure `after_transaction` receives
  # the changeset from before the transaction.

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.{Purge, Scope, Source}

  @state :__ash_storage__
  @deletions :__ash_storage_deletions__

  @doc """
  Attaches a file to the record written by the action.

  `input` is `{:upload, io, source_opts}`, bytes to upload, or
  `{:blob, blob_id}`, a blob uploaded directly to the service. Either is
  stored or confirmed, and analyzed, before the action writes the record, so
  that the analyzers' `write_attributes` are part of that write and a bad
  blob id fails before anything is written. The blob is linked to the record,
  and its variants and background jobs started, after the write. A blob the
  record already has under this attachment is only linked again.

  Options:

  - `:argument` - the action argument the input came from; tells apart two
    attachments made by the same action
  - `:metadata_keys` - `{blob_key, attachment_key}`, the metadata keys under
    which the result carries the blob and the attachment row
  """
  @spec attach(
          Ash.Changeset.t(),
          map(),
          atom(),
          {:upload, term(), keyword()} | {:blob, term()},
          keyword()
        ) :: Ash.Changeset.t()
  def attach(changeset, context, attachment_name, input, opts) do
    key = {attachment_name, Keyword.fetch!(opts, :argument)}
    {blob_key, attachment_key} = Keyword.fetch!(opts, :metadata_keys)
    nested? = nested?(changeset)

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      scope = Scope.from_change(changeset, context)

      with {:ok, target} <- Pipeline.resolve(changeset.resource, attachment_name),
           {:ok, blob, origin, attributes} <- prepare(input, target, scope, changeset) do
        state =
          Map.put(changeset.context[@state] || %{}, key, %{
            blob: blob,
            target: target,
            origin: origin
          })

        changeset
        |> Ash.Changeset.force_change_attributes(attributes)
        |> Ash.Changeset.put_context(@state, state)
      else
        {:error, reason} -> fail(:before_action, changeset, reason)
      end
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      case changeset.context[@state][key] do
        %{blob: blob, target: target, origin: origin} ->
          scope = Scope.from_change(changeset, context)

          with {:ok, linked} <- Pipeline.link(record, blob, target, scope),
               {:ok, blob} <- derive(origin, linked, target, scope) do
            {:ok,
             record
             |> Ash.Resource.put_metadata(blob_key, blob)
             |> Ash.Resource.put_metadata(attachment_key, linked.attachment)
             |> defer_deletions(linked.deletions, nested?)}
          else
            {:error, reason} -> fail(:after_action, changeset, reason)
          end

        nil ->
          {:ok, record}
      end
    end)
    |> delete_after_transaction(nested?)
  end

  defp prepare({:upload, io, source_opts}, target, scope, changeset) do
    source = Source.new(io, source_opts)

    with {:ok, blob, :stored} <- Pipeline.store(source, target, scope, changeset),
         {:ok, blob, attributes} <-
           Pipeline.analyze(blob, source, target, scope, changeset.data) do
      {:ok, blob, :stored, attributes}
    end
  end

  defp prepare({:blob, blob_id}, target, scope, changeset) do
    record = if changeset.action_type == :create, do: nil, else: changeset.data

    case Pipeline.adopt(blob_id, target, scope, record) do
      {:ok, blob, :linked} ->
        {:ok, blob, :linked, %{}}

      {:ok, blob, :adopted} ->
        with {:ok, blob, attributes} <-
               Pipeline.analyze(blob, :remote, target, scope, changeset.data) do
          {:ok, blob, :adopted, attributes}
        end

      {:error, _} = error ->
        error
    end
  end

  # A blob this record already had was derived when it came. On a create the
  # record is unknown before the write, as on an upsert, so only `link/4` can
  # tell that the row was there already.
  defp derive(:linked, %{blob: blob}, _target, _scope), do: {:ok, blob}
  defp derive(_origin, %{kept?: true, blob: blob}, _target, _scope), do: {:ok, blob}
  defp derive(_origin, %{blob: blob}, target, scope), do: Pipeline.derive(blob, target, scope)

  @doc """
  Turns a step's error into the failure of the hook it ran in: an error on
  the changeset before the action, the hook's `{:error, reason}` after it.
  """
  @spec fail(:before_action | :after_action, Ash.Changeset.t(), term()) ::
          Ash.Changeset.t() | {:error, term()}
  def fail(:before_action, changeset, reason), do: Ash.Changeset.add_error(changeset, reason)
  def fail(:after_action, _changeset, reason), do: {:error, reason}

  @doc """
  Whether the action runs inside a transaction someone else opened. Then
  `after_transaction` hooks run before that transaction commits anyway, and
  Ash warns about each of them, so an action whose own hooks are the last to
  run can delete files at the end of `after_action` instead. Call it from a
  `change/3` body.
  """
  @spec nested?(Ash.Changeset.t()) :: boolean()
  def nested?(changeset), do: Ash.DataLayer.in_transaction?(changeset.resource)

  @doc "Hands `deletions` to the `after_transaction` hook, or deletes them now when nested."
  @spec defer_deletions(struct(), [Purge.deletion()], boolean()) :: struct()
  def defer_deletions(record, [], _nested?), do: record

  def defer_deletions(record, deletions, true) do
    Purge.delete_files(deletions)
    record
  end

  def defer_deletions(record, deletions, false) do
    metadata = Map.update(record.__metadata__, @deletions, deletions, &(&1 ++ deletions))
    %{record | __metadata__: metadata}
  end

  @doc "Registers the hook that deletes the deferred files once the transaction committed."
  @spec delete_after_transaction(Ash.Changeset.t(), boolean()) :: Ash.Changeset.t()
  def delete_after_transaction(changeset, true), do: changeset

  def delete_after_transaction(changeset, false) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, record} ->
        {deletions, metadata} = Map.pop(record.__metadata__, @deletions, [])
        Purge.delete_files(deletions)
        {:ok, %{record | __metadata__: metadata}}

      _changeset, result ->
        result
    end)
  end
end
