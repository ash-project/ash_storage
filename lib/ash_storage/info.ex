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
  The value that identifies a resource in the `record_type` attribute of a
  polymorphic attachment resource (one with no `belongs_to_resource`).

  The library writes this value when it attaches a file, and matches on it when
  it loads or looks up attachments. It is the module name as a string, for
  example `"Elixir.MyApp.Post"`. Call this function instead of building the
  value yourself, for example when you query the attachment resource directly:

      require Ash.Query

      MyApp.Storage.Attachment
      |> Ash.Query.filter(record_type == ^AshStorage.Info.record_type(MyApp.Post))
      |> Ash.read!()

  Accepts a resource module or its DSL state.
  """
  @spec record_type(Ash.Resource.t() | Spark.Dsl.t()) :: String.t()
  def record_type(resource) when is_atom(resource), do: to_string(resource)

  def record_type(dsl_state) when is_map(dsl_state) do
    dsl_state
    |> Spark.Dsl.Extension.get_persisted(:module)
    |> record_type()
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

    result =
      with :error <- fetch_attachment_config(resource, entity_type, attachment.name, :service),
           nil <- attachment.service do
        Spark.Dsl.Extension.fetch_opt(resource, [:storage], :service, true)
      else
        {:ok, value} -> {:ok, value}
        {mod, opts} when is_atom(mod) -> {:ok, {mod, opts}}
      end

    case result do
      {:ok, tuple} -> {:ok, AshStorage.Service.Mirror.expand_sugar(tuple)}
      other -> other
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
