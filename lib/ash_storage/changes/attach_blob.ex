defmodule AshStorage.Changes.AttachBlob do
  @moduledoc """
  An action change that attaches a pre-uploaded blob (by ID) to the record.

  In a resource that uses the `AshStorage` extension, write it as
  `change attach_blob(:cover_image, argument: :cover_image_blob_id)`; see
  `AshStorage.Changes.Builtins.attach_blob/2`. The module and its options below
  are what that call expands to.

  Used for direct uploads where the file was uploaded directly to storage
  (e.g. via an S3 presigned URL or Azure Blob SAS URL) and the blob record already
  exists.

      create :create do
        accept [:title]
        argument :cover_image_blob_id, :uuid, allow_nil?: true

        change attach_blob(:cover_image, argument: :cover_image_blob_id)
      end

  The blob is confirmed with the service before the record is written. The
  attachment's analyzers and variants then run as for any other attach, which
  downloads the object when an eager analyzer or an eager variant needs its
  bytes. For `has_one_attached`, replaces any existing attachment (purging the
  old file). For `has_many_attached`, appends. Attaching a blob that is already
  attached is a no-op.

  ## Options

  - `:argument` - (required) the name of the blob ID argument on the action
  - `:attachment` - (required) the name of the attachment to attach to
  """
  use Ash.Resource.Change

  alias AshStorage.Pipeline.Hooks

  @impl true
  def init(opts) do
    with :ok <- validate_opt(opts, :argument),
         :ok <- validate_opt(opts, :attachment) do
      {:ok, opts}
    end
  end

  defp validate_opt(opts, key) do
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

      blob_id ->
        Hooks.attach(changeset, context, attachment, {:blob, blob_id},
          argument: argument,
          metadata_keys: {:"#{attachment}_blob", :"#{attachment}_attachment"}
        )
    end
  end
end
