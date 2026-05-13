defmodule AshStorage.Service.Context do
  @moduledoc """
  Context passed to all service callbacks.

  Contains the service-specific options along with broader context about the
  resource, attachment, actor, and tenant. This allows services to make
  decisions based on who is performing the operation and what resource/attachment
  it applies to.

  ## Fields

  - `:service_opts` - keyword options from the `{ServiceModule, opts}` tuple
  - `:resource` - the host resource module (e.g. `MyApp.Post`), or `nil`
  - `:attachment` - the `%AttachmentDefinition{}` struct, or `nil`
  - `:actor` - the current actor, or `nil`
  - `:tenant` - the current tenant, or `nil`
  - `:expected_md5` - base64-encoded raw MD5 (16 bytes → 24 chars) of the bytes
    being uploaded or expected to be downloaded. On `upload/3` it is sent as
    `Content-MD5` so S3/Azure reject mismatched bodies; on `download/2` it is
    compared against the hash of the fetched bytes. `nil` skips verification.
  """
  defstruct [
    :resource,
    :attachment,
    :actor,
    :tenant,
    :expected_md5,
    service_opts: []
  ]

  @type t :: %__MODULE__{
          resource: module() | nil,
          attachment: struct() | nil,
          actor: term(),
          tenant: term(),
          expected_md5: String.t() | nil,
          service_opts: keyword()
        }

  @doc """
  Build a context from service opts and optional extras.
  """
  def new(service_opts, extras \\ []) when is_list(service_opts) do
    %__MODULE__{
      service_opts: service_opts,
      resource: Keyword.get(extras, :resource),
      attachment: Keyword.get(extras, :attachment),
      actor: Keyword.get(extras, :actor),
      tenant: Keyword.get(extras, :tenant)
    }
  end

  @doc """
  Set or clear the expected MD5 on a context.

  The value must be a base64-encoded raw MD5 — exactly the format that the
  `Content-MD5` HTTP header expects.
  """
  def put_expected_md5(%__MODULE__{} = ctx, md5) when is_binary(md5) or is_nil(md5) do
    %{ctx | expected_md5: md5}
  end
end
