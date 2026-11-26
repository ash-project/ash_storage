defmodule AshStorage.Changes.AttachFileArgument do
  @moduledoc false
  # What `AshStorage.Changes.Builtins.attach_file/2` expands to
  use Ash.Resource.Change

  alias AshStorage.Pipeline.Hooks

  @impl true
  def init(opts) do
    with :ok <- require_opt(opts, :argument),
         :ok <- require_opt(opts, :attachment) do
      {:ok, opts}
    end
  end

  defp require_opt(opts, key) do
    if opts[key], do: :ok, else: {:error, "#{key} is required"}
  end

  # sobelow_skip ["DOS.BinToAtom"]
  @impl true
  def change(changeset, opts, context) do
    argument = opts[:argument]
    attachment = opts[:attachment]

    case Ash.Changeset.get_argument(changeset, argument) do
      nil ->
        changeset

      file ->
        Hooks.attach(changeset, context, attachment, {:upload, file, []},
          argument: argument,
          metadata_keys: {:"#{attachment}_blob", :"#{attachment}_attachment"}
        )
    end
  end
end
