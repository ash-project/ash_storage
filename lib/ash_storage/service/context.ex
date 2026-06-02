defmodule AshStorage.Service.Context do
  @moduledoc """
  Context passed to all service callbacks.

  Contains the service-specific options along with broader context about the
  resource, attachment, actor, and tenant. This allows services to make
  decisions based on who is performing the operation and what resource /
  attachment it applies to.

  ## Fields

  - `:service_opts` - keyword options from the `{ServiceModule, opts}` tuple
  - `:resource` - the host resource module (e.g. `MyApp.Post`), or `nil`
  - `:attachment` - the `%AttachmentDefinition{}` struct, or `nil`
  - `:actor` - the current actor, or `nil`
  - `:tenant` - the current tenant, or `nil`
  - `:expected_md5` - base64-encoded raw MD5 (16 bytes → 24 chars) of the bytes
    being uploaded or expected to be downloaded. On `upload/3` it is sent as
    `Content-MD5` so S3 / Azure reject mismatched bodies; on `download/2` it
    is compared against the hash of the fetched bytes. `nil` skips
    verification.
  - `:content_type` - MIME type of the bytes being uploaded (set by the
    bundled attach / file-argument changes from the caller-supplied
    `:content_type` option). Services use this to record the type on the
    underlying object — e.g. the S3 service forwards it as the
    `Content-Type` header on PUT. `nil` means the caller didn't supply one
    and the service should fall back to whatever default it normally uses.
  - `:filename` - original filename of the bytes being uploaded. Reserved
    for services that record it as object metadata (e.g. an S3
    `Content-Disposition` header, an Azure `x-ms-meta-filename` header).
    Not currently consumed by any bundled service. `nil` when unknown.

  ## Lifecycle

  Most callbacks see a Context constructed by the bundled changes
  (`AshStorage.Changes.Attach`, `HandleFileArgument`, etc.). Custom flows
  can build one with `new/2` and refine it via `put_expected_md5/2` and
  `put_blob_metadata/2` before invoking a service callback directly.
  """
  defstruct [
    :resource,
    :attachment,
    :actor,
    :tenant,
    :expected_md5,
    :content_type,
    :filename,
    service_opts: []
  ]

  @type t :: %__MODULE__{
          resource: module() | nil,
          attachment: struct() | nil,
          actor: term(),
          tenant: term(),
          expected_md5: String.t() | nil,
          content_type: String.t() | nil,
          filename: String.t() | nil,
          service_opts: keyword()
        }

  @doc """
  Build a context from service opts and optional extras.

  Recognized keys in `extras`: `:resource`, `:attachment`, `:actor`,
  `:tenant`, `:content_type`, `:filename`. Anything else is ignored.
  """
  def new(service_opts, extras \\ []) when is_list(service_opts) do
    %__MODULE__{
      service_opts: service_opts,
      resource: Keyword.get(extras, :resource),
      attachment: Keyword.get(extras, :attachment),
      actor: Keyword.get(extras, :actor),
      tenant: Keyword.get(extras, :tenant),
      content_type: Keyword.get(extras, :content_type),
      filename: Keyword.get(extras, :filename)
    }
  end

  @doc """
  Set or clear the expected MD5 on a context.

  The value must be a base64-encoded raw MD5 — exactly the format that the
  `Content-MD5` HTTP header expects. Pass `nil` to disable verification.
  """
  def put_expected_md5(%__MODULE__{} = ctx, md5) when is_binary(md5) or is_nil(md5) do
    %{ctx | expected_md5: md5}
  end

  @doc """
  Set the blob's `:content_type` and / or `:filename` on the context.

  Used by the bundled attach changes to forward caller-supplied metadata
  to the service before calling `upload/3`. Pass only the keys you want
  to update; existing values are preserved for keys you don't supply.

  ## Examples

      iex> ctx = AshStorage.Service.Context.new([])
      iex> ctx = AshStorage.Service.Context.put_blob_metadata(ctx, content_type: "image/jpeg")
      iex> ctx.content_type
      "image/jpeg"

      iex> ctx = AshStorage.Service.Context.new([], content_type: "image/png")
      iex> ctx = AshStorage.Service.Context.put_blob_metadata(ctx, filename: "cover.png")
      iex> {ctx.content_type, ctx.filename}
      {"image/png", "cover.png"}
  """
  def put_blob_metadata(%__MODULE__{} = ctx, opts) when is_list(opts) do
    %{
      ctx
      | content_type: Keyword.get(opts, :content_type, ctx.content_type),
        filename: Keyword.get(opts, :filename, ctx.filename)
    }
  end
end
