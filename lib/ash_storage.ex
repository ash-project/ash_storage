defmodule AshStorage do
  @moduledoc """
  An Ash extension for adding file attachments to a resource.

  AshStorage provides a consistent interface for uploading, storing, and managing
  file attachments on Ash resources. It supports multiple storage backends
  (local disk, S3) and per-environment configuration.

  ## Getting started

  1. Create a blob resource with `AshStorage.BlobResource`
  2. Create an attachment resource with `AshStorage.AttachmentResource`
  3. Add `AshStorage` to your host resource and declare attachments

  ## Usage

      defmodule MyApp.Post do
        use Ash.Resource,
          extensions: [AshStorage]

        storage do
          has_one_attached :cover_image do
            analyzer {MyApp.ImageDimensions, format: :png}, analyze: :oban
          end

          has_many_attached :documents
        end
      end

  ## Configuration

  The `service` option can be overridden per-environment using application config:

      config :my_app, MyApp.Post,
        storage: [service: {AshStorage.Service.Test, []}]

  ## Core modules

  - `AshStorage` — DSL extension for host resources
  - `AshStorage.BlobResource` — DSL extension for blob metadata resources
  - `AshStorage.AttachmentResource` — DSL extension for attachment join resources
  - `AshStorage.Operations` — Functions for attaching, detaching, and purging files
  - `AshStorage.Service` — Behaviour for storage backends
  - `AshStorage.Key` — The rules for storage keys
  """

  alias AshStorage.AnalyzerDefinition
  alias AshStorage.AttachmentDefinition
  alias AshStorage.VariantDefinition

  @analyzer %Spark.Dsl.Entity{
    name: :analyzer,
    args: [:module],
    describe: "Declares an analyzer to run on uploaded files for this attachment.",
    examples: [
      "analyzer MyApp.FileInfo",
      "analyzer {MyApp.ImageDimensions, format: :png}, analyze: :oban",
      "analyzer MyApp.Thumbnailer, write_attributes: [thumbnail_url: :thumbnail_url]"
    ],
    schema: AnalyzerDefinition.schema(),
    target: AnalyzerDefinition
  }

  @variant %Spark.Dsl.Entity{
    name: :variant,
    args: [:name, :module],
    describe: "Declares a named variant transformation for this attachment.",
    examples: [
      "variant :thumbnail, {MyApp.ImageResize, width: 200, height: 200}",
      "variant :hero, {MyApp.ImageResize, width: 1200, format: :jpg}, generate: :eager",
      "variant :pdf_preview, MyApp.PdfThumbnail, generate: :oban"
    ],
    schema: VariantDefinition.schema(),
    target: VariantDefinition
  }

  @has_one_attached %Spark.Dsl.Entity{
    name: :has_one_attached,
    args: [:name],
    describe: "Declares a single file attachment on this resource.",
    examples: [
      "has_one_attached :avatar",
      ~s(has_one_attached :cover_image, service: {AshStorage.Service.Disk, root: "priv/storage"})
    ],
    schema: AttachmentDefinition.has_one_schema(),
    target: AttachmentDefinition,
    auto_set_fields: [type: :one],
    entities: [
      analyzers: [@analyzer],
      variants: [@variant]
    ]
  }

  @has_many_attached %Spark.Dsl.Entity{
    name: :has_many_attached,
    args: [:name],
    describe: "Declares a collection of file attachments on this resource.",
    examples: [
      "has_many_attached :documents",
      "has_many_attached :photos, dependent: :detach"
    ],
    schema: AttachmentDefinition.has_many_schema(),
    target: AttachmentDefinition,
    auto_set_fields: [type: :many],
    entities: [
      analyzers: [@analyzer],
      variants: [@variant]
    ]
  }

  @storage %Spark.Dsl.Section{
    name: :storage,
    describe: "Configure file storage and attachments for this resource.",
    schema: [
      service: [
        type: {:tuple, [:module, :keyword_list]},
        doc:
          "The default storage service for all attachments on this resource, as a `{module, opts}` tuple. Can be overridden per-attachment or via application config.",
        required: false
      ],
      blob_resource: [
        type: :module,
        required: true,
        doc: "The blob resource module (must use `AshStorage.BlobResource` extension)."
      ],
      attachment_resource: [
        type: :module,
        required: true,
        doc:
          "The attachment resource module (must use `AshStorage.AttachmentResource` extension)."
      ]
    ],
    entities: [
      @has_one_attached,
      @has_many_attached
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@storage],
    transformers: [AshStorage.Transformers.SetupStorage],
    verifiers: [
      AshStorage.Verifiers.ValidateObanAnalyzers,
      AshStorage.Verifiers.ValidateObanVariants
    ]

  @doc """
  Generate a unique key for storing a file.

  Returns a 56-character lowercase hex string.
  """
  def generate_key do
    Base.encode16(:crypto.strong_rand_bytes(28), case: :lower)
  end

  @doc """
  Resolve the storage key for an attachment during upload.

  Using the following priority:
  1. Use `path` specified on the attachment definition (2-arity function) e.g.

         has_one_attached :avatar do
           path fn ctx, _changeset ->
             "\#{ctx.actor.org_id}/\#{AshStorage.generate_key()}"
           end
         end

  2. Tenant i.e. "\#{tenant_id}/\#{key}"
  3. Just the randomly generated key

  `changeset` is `nil` when there is no parent action, as in
  `AshStorage.Operations.prepare_direct_upload/3`. The tenant then comes from the context.

  Returns `{:ok, key}`, or `{:error, error}` when the key breaks the rules in
  `AshStorage.Key` or the tenant cannot be used as a key segment. Nothing has
  been uploaded or created at that point.
  """
  @spec resolve_key(
          AttachmentDefinition.t(),
          AshStorage.Service.Context.t(),
          Ash.Changeset.t() | nil
        ) ::
          {:ok, String.t()} | {:error, AshStorage.Key.error()}
  def resolve_key(attachment_def, context, changeset) do
    resolved =
      case attachment_def.path do
        nil ->
          resolve_tenant_key(tenant(context, changeset), context.resource)

        "" ->
          resolve_tenant_key(tenant(context, changeset), context.resource)

        path_fn when is_function(path_fn, 2) ->
          {:ok, path_fn.(context, changeset)}
      end

    validated(resolved)
  end

  @doc """
  Resolve the storage key for a variant from the source blob's key.

  The variant is stored next to its source: the key is the source key with its
  last segment replaced by a new generated key. Returns `{:ok, key}`, or
  `{:error, error}` when the result breaks the rules in `AshStorage.Key`.
  """
  @spec resolve_variant_key(String.t()) :: {:ok, String.t()} | {:error, AshStorage.Key.error()}
  def resolve_variant_key(source_blob_key) do
    case source_blob_key |> String.split("/") |> Enum.drop(-1) do
      [] -> {:ok, generate_key()}
      segments -> validated({:ok, Enum.join(segments ++ [generate_key()], "/")})
    end
  end

  defp validated({:ok, key}) do
    with :ok <- AshStorage.Key.validate(key), do: {:ok, key}
  end

  defp validated({:error, _} = error), do: error

  defp tenant(context, nil), do: context.tenant
  defp tenant(_context, changeset), do: changeset.tenant

  defp resolve_tenant_key(tenant, resource) do
    case tenant_prefix(tenant, resource) do
      "" ->
        {:ok, generate_key()}

      prefix ->
        with :ok <- AshStorage.Key.validate_tenant(prefix) do
          {:ok, prefix <> "/" <> generate_key()}
        end
    end
  end

  defp tenant_prefix(nil, _resource), do: ""
  defp tenant_prefix(tenant, _resource) when is_binary(tenant), do: tenant
  defp tenant_prefix(tenant, resource), do: to_string(Ash.ToTenant.to_tenant(tenant, resource))
end
