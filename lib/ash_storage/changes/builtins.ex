defmodule AshStorage.Changes.Builtins do
  @moduledoc """
  Changes for attaching files from an action's arguments.

  Resources that use the `AshStorage` extension can call these functions in
  their actions without importing anything:

      create :create do
        accept [:title]
        argument :cover_image, :file, allow_nil?: true

        change attach_file(:cover_image)
      end

      create :create_from_upload do
        accept [:title]
        argument :cover_image_blob_id, :uuid, allow_nil?: true

        change attach_blob(:cover_image, argument: :cover_image_blob_id)
      end

  Both work in create and update actions. An update action needs
  `require_atomic? false`, because the file is uploaded or confirmed before the
  record is written. When the argument is `nil` nothing is attached.

  For a `has_one_attached`, an existing file is replaced; for a
  `has_many_attached`, the file is added. The attachment's analyzers run before
  the record is written, so their `write_attributes` are part of the same
  write, and its variants and background jobs start after it.

  The result carries the blob and the attachment row in its metadata, under
  `:<attachment>_blob` and `:<attachment>_attachment`.

  When the resource compiles, each create and update action's own `change`
  entries are checked: an attachment the resource does not declare, or an
  argument the action does not have, is reported as a warning. If it is left
  in, an action with a wrong attachment fails when it is given a file or blob
  id and attaches nothing when it is not; an action without the argument never
  attaches anything. Changes in the resource's `changes` section are not
  checked.
  """

  @doc """
  Attaches the file passed in an action argument.

  The argument is an `Ash.Type.File` (declare it as `:file`). Its filename and
  content type, when the file has them, are stored on the blob.

  ## Options

  - `:argument` - the name of the argument that holds the file. Defaults to the
    attachment's name.

  ## Examples

      change attach_file(:cover_image)
      change attach_file(:cover_image, argument: :upload)
  """
  @spec attach_file(attachment :: atom(), opts :: keyword()) :: {module(), keyword()}
  def attach_file(attachment, opts \\ []) do
    {AshStorage.Changes.HandleFileArgument, build(:attach_file, attachment, opts)}
  end

  @doc """
  Attaches a blob that was uploaded directly to the storage service, by the
  blob id passed in an action argument.

  The blob comes from `AshStorage.Operations.prepare_direct_upload/3`. It is
  confirmed with the service before the record is written; see the
  "Direct Uploads" guide.

  ## Options

  - `:argument` - the name of the argument that holds the blob id. Defaults to
    the attachment's name.

  ## Examples

      change attach_blob(:cover_image, argument: :cover_image_blob_id)
      change attach_blob(:cover_image)
  """
  @spec attach_blob(attachment :: atom(), opts :: keyword()) :: {module(), keyword()}
  def attach_blob(attachment, opts \\ []) do
    {AshStorage.Changes.AttachBlob, build(:attach_blob, attachment, opts)}
  end

  defp build(function, attachment, opts) do
    unless is_atom(attachment) and not is_nil(attachment) do
      raise ArgumentError,
            "#{function}/2 expects the attachment's name as an atom, got: #{inspect(attachment)}"
    end

    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "#{function}/2 expects a keyword list of options, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- [:argument] do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option#{if length(unknown) > 1, do: "s"} #{Enum.map_join(unknown, ", ", &inspect/1)} " <>
                "for #{function}/2; the only option is :argument"
    end

    argument = Keyword.get(opts, :argument, attachment)

    unless is_atom(argument) and not is_nil(argument) do
      raise ArgumentError,
            "#{function}/2 expects :argument to be an atom, got: #{inspect(argument)}"
    end

    [argument: argument, attachment: attachment]
  end
end
