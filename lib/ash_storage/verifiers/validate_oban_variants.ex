defmodule AshStorage.Verifiers.ValidateObanVariants do
  @moduledoc false
  use Spark.Dsl.Verifier

  @required_actions [
    :run_pending_variant,
    :run_pending_variants,
    :schedule_pending_variants
  ]

  def verify(dsl_state) do
    has_one_attachments = AshStorage.Info.has_one_attachments(dsl_state)
    has_many_attachments = AshStorage.Info.has_many_attachments(dsl_state)
    oban_variants = oban_variants(has_one_attachments ++ has_many_attachments)

    with :not_empty <- if(oban_variants == [], do: :ok, else: :not_empty),
         :ok <- validate_groups(oban_variants),
         {:ok, blob_resource} <- AshStorage.Info.storage_blob_resource(dsl_state),
         :ok <- if(Code.ensure_loaded?(AshOban.Info), do: :ok, else: {:error, oban_error()}) do
      triggers = AshOban.Info.oban_triggers(blob_resource)
      trigger_actions = Enum.map(triggers, & &1.action)
      missing = @required_actions -- trigger_actions
      if missing == [], do: :ok, else: {:error, triggers_error(blob_resource, missing)}
    end
  end

  defp oban_variants(attachments) do
    Enum.flat_map(attachments, fn attachment_def ->
      Enum.filter(attachment_def.variants || [], &(&1.generate == :oban))
    end)
  end

  defp validate_groups(oban_variants) do
    oban_variants
    |> Enum.filter(& &1.group)
    |> Enum.group_by(& &1.group)
    |> Enum.find_value(:ok, fn {group, defns} ->
      orders = defns |> Enum.map(& &1.order) |> Enum.uniq()

      case orders do
        [_single] ->
          nil

        multiple ->
          {:error,
           Spark.Error.DslError.exception(
             message: """
             Variants in group #{inspect(group)} declare conflicting `order:` \
             values: #{Enum.map_join(multiple, ", ", &inspect/1)}.

             All variants in a group share a single Oban job, so they must \
             share a single dispatch tier. Pick one `order:` for the group.
             """
           )}
      end
    end)
  end

  defp oban_error do
    Spark.Error.DslError.exception(
      message: """
      One or more variants use `generate: :oban`, but `ash_oban` is not available. \
      Add `{:ash_oban, "~> 0.7"}` to your dependencies.
      """
    )
  end

  defp triggers_error(blob_resource, missing) do
    Spark.Error.DslError.exception(
      message: """
      One or more variants use `generate: :oban`, but the blob resource \
      `#{inspect(blob_resource)}` is missing AshOban trigger(s) for the following \
      action(s): #{Enum.map_join(missing, ", ", &inspect/1)}.

      Add the missing oban triggers to your blob resource:

          oban do
            triggers do
              trigger :run_pending_variant do
                action :run_pending_variant
                read_action :read
                max_attempts 3
              end

              trigger :run_pending_variants do
                action :run_pending_variants
                read_action :read
                max_attempts 3
              end

              trigger :schedule_pending_variants do
                action :schedule_pending_variants
                read_action :read
                where expr(pending_variants == true)
                scheduler_cron "* * * * *"
                max_attempts 3
              end
            end
          end

      `:run_pending_variant` is the canonical per-variant worker — one Oban \
      job per variant. The scheduler enqueues solo variants directly through \
      this action. `:run_pending_variants` is the multi-unit dispatcher that \
      handles group jobs (one job per group, members run serially) and \
      delegates per-variant work back to `:run_pending_variant`. \
      `:schedule_pending_variants` is the cron-driven recovery dispatcher \
      that re-fans-out the lowest still-pending tier for any blob still \
      flagged `pending_variants == true`.
      """
    )
  end
end
