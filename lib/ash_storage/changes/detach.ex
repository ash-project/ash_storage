defmodule AshStorage.Changes.Detach do
  @moduledoc false
  use Ash.Resource.Change

  alias AshStorage.Pipeline
  alias AshStorage.Pipeline.Scope

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, context) do
    attachment_name = opts[:attachment_name]

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      scope = Scope.from_change(changeset, context)
      blob_id = Ash.Changeset.get_argument(changeset, :blob_id)
      all? = Ash.Changeset.get_argument(changeset, :all) || false

      with {:ok, target} <- Pipeline.resolve(record.__struct__, attachment_name),
           {:ok, attachments} <- Pipeline.attachments(record, target, scope),
           {:ok, to_detach} <- Pipeline.select(attachments, target, blob_id, all?),
           {:ok, %{attachments: detached}} <- Pipeline.unlink(to_detach, :detach, target, scope) do
        {:ok, Ash.Resource.put_metadata(record, :detached_attachments, detached)}
      end
    end)
  end
end
