defmodule AshStorage.Verifiers.ValidateAttachChanges do
  @moduledoc false
  # A change that attaches from an argument names an attachment and an argument.
  # A wrong name would otherwise only show when the action runs.
  use Spark.Dsl.Verifier

  @changes [
    AshStorage.Changes.HandleFileArgument,
    AshStorage.Changes.AttachFile,
    AshStorage.Changes.AttachBlob
  ]

  def verify(dsl_state) do
    resource = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)
    attachments = dsl_state |> AshStorage.Info.attachments() |> Enum.map(& &1.name)

    dsl_state
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&(&1.type in [:create, :update]))
    |> Enum.flat_map(fn action -> Enum.map(action.changes, &{action, &1}) end)
    |> Enum.reduce_while(:ok, fn
      {action, %Ash.Resource.Change{change: {module, opts}}}, :ok when module in @changes ->
        case problem(action, opts, attachments) do
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

      _, :ok ->
        {:cont, :ok}
    end)
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
