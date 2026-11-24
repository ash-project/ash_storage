# Two copies of one host, blob and attachment resource shape: one with context
# multitenancy on all three, one with policies on the blob and the attachment.

defmodule AshStorage.Test.TenantMatrixBlob do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage.BlobResource]

  ets do
    private? true
  end

  multitenancy do
    strategy :context
  end

  blob do
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshStorage.Test.TenantMatrixAttachment do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage.AttachmentResource]

  ets do
    private? true
  end

  multitenancy do
    strategy :context
  end

  attachment do
    blob_resource(AshStorage.Test.TenantMatrixBlob)
    belongs_to_resource(:post, AshStorage.Test.TenantMatrixPost)
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshStorage.Test.TenantMatrixPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  ets do
    private? true
  end

  multitenancy do
    strategy :context
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.TenantMatrixBlob)
    attachment_resource(AshStorage.Test.TenantMatrixAttachment)

    has_one_attached(:doc)

    has_one_attached :eager do
      variant(:upper, AshStorage.Test.UppercaseVariant, generate: :eager)
    end

    has_one_attached :lazy do
      variant(:upper, AshStorage.Test.UppercaseVariant)
    end
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :destroy, create: [], update: []]

    create :create_with_doc do
      argument :doc, :file, allow_nil?: true

      change {AshStorage.Changes.HandleFileArgument, argument: :doc, attachment: :doc}
    end

    create :create_with_doc_blob do
      argument :doc_blob_id, :uuid, allow_nil?: true

      change {AshStorage.Changes.AttachBlob, argument: :doc_blob_id, attachment: :doc}
    end

    for name <- [:doc, :eager] do
      update :"update_#{name}" do
        require_atomic? false
        argument name, :file, allow_nil?: true

        change {AshStorage.Changes.HandleFileArgument, argument: name, attachment: name}
      end

      update :"update_#{name}_blob" do
        require_atomic? false
        argument :"#{name}_blob_id", :uuid, allow_nil?: true

        change {AshStorage.Changes.AttachBlob, argument: :"#{name}_blob_id", attachment: name}
      end
    end
  end
end

defmodule AshStorage.Test.PolicyMatrixBlob do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStorage.BlobResource]

  ets do
    private? true
  end

  blob do
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshStorage.Test.PolicyMatrixAttachment do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStorage.AttachmentResource]

  ets do
    private? true
  end

  attachment do
    blob_resource(AshStorage.Test.PolicyMatrixBlob)
    belongs_to_resource(:post, AshStorage.Test.PolicyMatrixPost)
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
  end
end

defmodule AshStorage.Test.PolicyMatrixPost do
  @moduledoc false
  use Ash.Resource,
    domain: AshStorage.Test.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshStorage]

  ets do
    private? true
  end

  storage do
    service({AshStorage.Service.Test, []})
    blob_resource(AshStorage.Test.PolicyMatrixBlob)
    attachment_resource(AshStorage.Test.PolicyMatrixAttachment)

    has_one_attached(:doc)

    has_one_attached :eager do
      variant(:upper, AshStorage.Test.UppercaseVariant, generate: :eager)
    end

    has_one_attached :lazy do
      variant(:upper, AshStorage.Test.UppercaseVariant)
    end
  end

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :destroy, create: [], update: []]

    create :create_with_doc do
      argument :doc, :file, allow_nil?: true

      change {AshStorage.Changes.HandleFileArgument, argument: :doc, attachment: :doc}
    end

    create :create_with_doc_blob do
      argument :doc_blob_id, :uuid, allow_nil?: true

      change {AshStorage.Changes.AttachBlob, argument: :doc_blob_id, attachment: :doc}
    end

    for name <- [:doc, :eager] do
      update :"update_#{name}" do
        require_atomic? false
        argument name, :file, allow_nil?: true

        change {AshStorage.Changes.HandleFileArgument, argument: name, attachment: name}
      end

      update :"update_#{name}_blob" do
        require_atomic? false
        argument :"#{name}_blob_id", :uuid, allow_nil?: true

        change {AshStorage.Changes.AttachBlob, argument: :"#{name}_blob_id", attachment: name}
      end
    end
  end
end
