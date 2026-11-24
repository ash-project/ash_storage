defmodule AshStorage.Changes.Attach do
  @moduledoc false
  use Ash.Resource.Change

  alias AshStorage.Pipeline.Hooks

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, context) do
    source_opts = [
      filename: Ash.Changeset.get_argument(changeset, :filename),
      content_type:
        Ash.Changeset.get_argument(changeset, :content_type) || "application/octet-stream",
      metadata: Ash.Changeset.get_argument(changeset, :metadata) || %{}
    ]

    Hooks.attach(
      changeset,
      context,
      opts[:attachment_name],
      {:upload, Ash.Changeset.get_argument(changeset, :io), source_opts},
      argument: :io,
      metadata_keys: {:blob, :attachment}
    )
  end
end
