defmodule AshStorage.Info do
  @moduledoc "Introspection helpers for `AshStorage`"
  use Spark.InfoGenerator, extension: AshStorage, sections: [:storage]

  @doc "All attachment definitions on the resource"
  def attachments(resource) do
    resource
    |> storage()
    |> Enum.filter(&match?(%AshStorage.AttachmentDefinition{}, &1))
  end

  @doc "All has_one_attached definitions on the resource"
  def has_one_attachments(resource) do
    resource |> attachments() |> Enum.filter(&(&1.type == :one))
  end

  @doc "All has_many_attached definitions on the resource"
  def has_many_attachments(resource) do
    resource |> attachments() |> Enum.filter(&(&1.type == :many))
  end

  @doc "Get a specific attachment by name"
  def attachment(resource, name) do
    case Enum.find(attachments(resource), &(&1.name == name)) do
      nil -> :error
      att -> {:ok, att}
    end
  end

  @doc """
  Get the effective service for an attachment.

  Resolution order:
  1. Per-attachment app config: `config :my_app, MyResource, storage: [has_one_attached: [name: [service: ...]]]`
  2. Per-attachment `service` option in the DSL
  3. Resource-level app config: `config :my_app, MyResource, storage: [service: ...]`
  4. Resource-level `service` option in the DSL
  """
  def service_for_attachment(resource, attachment) do
    entity_type =
      case attachment.type do
        :one -> :has_one_attached
        :many -> :has_many_attached
      end

    with :error <- fetch_attachment_config(resource, entity_type, attachment.name, :service),
         nil <- attachment.service do
      Spark.Dsl.Extension.fetch_opt(resource, [:storage], :service, true)
    else
      {:ok, value} -> {:ok, value}
      {mod, opts} when is_atom(mod) -> {:ok, {mod, opts}}
    end
  end

  defp fetch_attachment_config(resource, entity_type, name, key) do
    with otp_app when not is_nil(otp_app) <-
           Spark.Dsl.Extension.get_persisted(resource, :otp_app),
         {:ok, config} <- Application.fetch_env(otp_app, resource),
         {:ok, storage_config} <- Keyword.fetch(config, :storage),
         {:ok, entity_configs} <- Keyword.fetch(storage_config, entity_type),
         {:ok, attachment_config} <- Keyword.fetch(entity_configs, name),
         {:ok, value} <- Keyword.fetch(attachment_config, key) do
      {:ok, value}
    else
      _ -> :error
    end
  end
end
