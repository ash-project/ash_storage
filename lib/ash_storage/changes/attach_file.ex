defmodule AshStorage.Changes.AttachFile do
  @moduledoc """
  An action change that attaches a file from an argument to the record.

  Typically added automatically by the `attachment_argument` DSL option (not yet implemented),
  or added manually to an action:

      create :create do
        argument :cover_image, :file, allow_nil?: true

        change {AshStorage.Changes.AttachFile,
                argument: :cover_image, attachment: :cover_image}
      end

  ## Options

  - `:argument` - (required) the name of the `:file` argument on the action
  - `:attachment` - (required) the name of the attachment to attach to
  """
  use Ash.Resource.Change

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

  @impl true
  def change(changeset, opts, context) do
    argument = opts[:argument]
    attachment = opts[:attachment]

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      case Ash.Changeset.get_argument(changeset, argument) do
        nil ->
          {:ok, record}

        %Ash.Type.File{} = file ->
          {filename, content_type} = AshStorage.Pipeline.Source.name_and_type(file)
          context_opts = Ash.Context.to_opts(context)

          attach_opts =
            Keyword.merge(context_opts, filename: filename, content_type: content_type)

          case AshStorage.Operations.attach(record, attachment, file, attach_opts) do
            {:ok, _} -> {:ok, record}
            {:error, error} -> {:error, error}
          end
      end
    end)
  end

  @impl true
  def batch_change(changesets, _opts, _context), do: changesets

  @impl true
  def after_batch(changesets_and_results, opts, context) do
    argument = opts[:argument]
    attachment = opts[:attachment]
    context_opts = Ash.Context.to_opts(context)

    # Split into items that need attachment and those that don't
    {to_attach, passthrough} =
      changesets_and_results
      |> Enum.with_index()
      |> Enum.split_with(fn {{changeset, _result}, _idx} ->
        match?(%Ash.Type.File{}, Ash.Changeset.get_argument(changeset, argument))
      end)

    # Build the attach items
    attach_items =
      Enum.map(to_attach, fn {{changeset, result}, _idx} ->
        file = Ash.Changeset.get_argument(changeset, argument)
        {filename, content_type} = AshStorage.Pipeline.Source.name_and_type(file)

        attach_opts =
          Keyword.merge(context_opts, filename: filename, content_type: content_type)

        {result, attachment, file, attach_opts}
      end)

    # Attach one at a time, in input order
    attach_results =
      Enum.map(attach_items, fn {record, attachment, file, attach_opts} ->
        AshStorage.Operations.attach(record, attachment, file, attach_opts)
      end)

    # Map the results back, converting {:ok, _attach_result} to {:ok, record}
    indexed_attach_results =
      Enum.zip(to_attach, attach_results)
      |> Enum.map(fn {{{_changeset, result}, idx}, attach_result} ->
        mapped =
          case attach_result do
            {:ok, _} -> {:ok, result}
            {:error, error} -> {:error, error}
          end

        {idx, mapped}
      end)

    # Combine with passthrough items
    indexed_passthrough =
      Enum.map(passthrough, fn {{_changeset, result}, idx} ->
        {idx, {:ok, result}}
      end)

    (indexed_attach_results ++ indexed_passthrough)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end
end
