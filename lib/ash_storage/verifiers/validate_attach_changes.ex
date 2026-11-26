defmodule AshStorage.Verifiers.ValidateAttachChanges do
  @moduledoc false
  # A change that attaches from an argument names an attachment and an argument.
  # A wrong name would otherwise only show when the action runs. A change that
  # names one of the removed file-argument modules compiles without a word and
  # raises whenever the action is called, so it is pointed at here as well. The
  # removed modules are compared by name only; they no longer exist to load.
  use Spark.Dsl.Verifier

  @changes [AshStorage.Changes.AttachFileArgument, AshStorage.Changes.AttachBlob]
  @removed [AshStorage.Changes.HandleFileArgument, AshStorage.Changes.AttachFile]

  def verify(dsl_state) do
    resource = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)
    attachments = dsl_state |> AshStorage.Info.attachments() |> Enum.map(& &1.name)

    dsl_state
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&(&1.type in [:create, :update]))
    |> Enum.flat_map(fn action -> Enum.map(action.changes, &{action, &1}) end)
    |> Enum.reduce_while(:ok, fn {action, entry}, :ok ->
      case check_entry(action, entry, attachments) do
        nil ->
          {:cont, :ok}

        message ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: resource,
              path: [:actions, action.name],
              message: message
            )}}
      end
    end)
  end

  # An action's `changes` also holds its `validate` entries; only changes are
  # looked at, and only in the two shapes a `change` takes
  defp check_entry(action, %Ash.Resource.Change{change: {module, opts}}, attachments)
       when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts), do: check(action, {module, opts}, attachments)
  end

  defp check_entry(action, %Ash.Resource.Change{change: module}, attachments)
       when is_atom(module),
       do: check(action, module, attachments)

  defp check_entry(_action, _entry, _attachments), do: nil

  defp check(action, {module, opts}, _attachments) when module in @removed,
    do: removed(action, module, replacement(opts[:attachment], opts[:argument]))

  defp check(action, module, _attachments) when module in @removed,
    do: removed(action, module, "attach_file/2")

  defp check(action, {module, opts}, attachments) when module in @changes,
    do: problem(action, opts, attachments)

  defp check(_action, _change, _attachments), do: nil

  defp replacement(nil, _argument), do: "attach_file/2"

  defp replacement(attachment, argument) when argument in [nil, attachment],
    do: "change attach_file(#{inspect(attachment)})"

  defp replacement(attachment, argument),
    do: "change attach_file(#{inspect(attachment)}, argument: #{inspect(argument)})"

  defp removed(action, module, replacement) do
    "action #{inspect(action.name)} uses #{inspect(module)}, which was removed, so the " <>
      "action raises when it is called. Use #{replacement} instead; see " <>
      "AshStorage.Changes.Builtins.attach_file/2"
  end

  defp problem(action, opts, attachments) do
    attachment = opts[:attachment]
    argument = opts[:argument]

    cond do
      attachment not in attachments ->
        "action #{inspect(action.name)} attaches to #{inspect(attachment)}, which is not an " <>
          "attachment of this resource. Declared attachments: #{inspect(attachments)}"

      argument not in Enum.map(action.arguments, & &1.name) ->
        "action #{inspect(action.name)} attaches #{inspect(attachment)} from the argument " <>
          "#{inspect(argument)}, which the action does not have"

      true ->
        nil
    end
  end
end
