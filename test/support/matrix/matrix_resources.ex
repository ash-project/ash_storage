defmodule AshStorage.Test.MatrixResources do
  @moduledoc false
  # Defines `Blob`, `Attachment` and `Post` under the calling module: the
  # attachments and actions of `AshStorage.Test.MatrixPost`, over a blob and an
  # attachment resource (with `belongs_to_resource`) of their own, with the
  # given resource configuration.
  #
  # Options:
  #
  #   * `:multitenancy` - `nil`, `:context`, or `:attribute` (on `:org_id`, on
  #     all three resources)
  #   * `:policies` - `nil`, or `:actor` for `authorize_if actor_present()` on
  #     the blob and the attachment resource

  defmacro __using__(opts) do
    parent = __CALLER__.module
    blob = Module.concat(parent, Blob)
    attachment = Module.concat(parent, Attachment)
    post = Module.concat(parent, Post)

    multitenancy = Keyword.get(opts, :multitenancy)
    policies = Keyword.get(opts, :policies)

    tenancy = tenancy(multitenancy)
    org_id = org_id(multitenancy)
    storage_policies = storage_policies(policies)
    storage_authorizers = if policies, do: [Ash.Policy.Authorizer], else: []

    quote do
      defmodule unquote(blob) do
        @moduledoc false
        use Ash.Resource,
          domain: AshStorage.Test.Domain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: unquote(storage_authorizers),
          extensions: [AshStorage.BlobResource]

        ets do
          private? true
        end

        unquote(tenancy)
        unquote(storage_policies)

        blob do
        end

        attributes do
          uuid_primary_key :id
          unquote(org_id)
        end
      end

      defmodule unquote(attachment) do
        @moduledoc false
        use Ash.Resource,
          domain: AshStorage.Test.Domain,
          data_layer: Ash.DataLayer.Ets,
          authorizers: unquote(storage_authorizers),
          extensions: [AshStorage.AttachmentResource]

        ets do
          private? true
        end

        unquote(tenancy)
        unquote(storage_policies)

        attachment do
          blob_resource(unquote(blob))
          belongs_to_resource(:post, unquote(post))
        end

        attributes do
          uuid_primary_key :id
          unquote(org_id)
        end
      end

      defmodule unquote(post) do
        @moduledoc false
        use Ash.Resource,
          domain: AshStorage.Test.Domain,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshStorage]

        ets do
          private? true
        end

        unquote(tenancy)

        storage do
          service({AshStorage.Service.Test, []})
          blob_resource(unquote(blob))
          attachment_resource(unquote(attachment))

          has_one_attached :doc do
            analyzer(AshStorage.Test.TestAnalyzer, write_attributes: [line_count: :lines])
            analyzer(AshStorage.Test.FailingAnalyzer)
            variant(:upper, AshStorage.Test.UppercaseVariant, generate: :eager)
          end

          has_many_attached :files do
            variant(:upper, AshStorage.Test.UppercaseVariant, generate: :eager)
          end

          has_one_attached :fragile do
            variant(:checked, AshStorage.Test.FailOnMarkerVariant, generate: :eager)
          end

          has_one_attached(:plain)

          has_one_attached :lazy do
            variant(:upper, AshStorage.Test.UppercaseVariant)
          end
        end

        attributes do
          uuid_primary_key :id
          attribute :slug, :string, allow_nil?: false, public?: true
          attribute :lines, :integer, public?: true
          unquote(org_id)
        end

        identities do
          identity :unique_slug, [:slug], pre_check_with: AshStorage.Test.Domain
        end

        actions do
          defaults [:read, :destroy, create: [:slug], update: [:slug]]

          create :create_with_doc do
            accept [:slug]
            argument :doc, :file, allow_nil?: true

            change attach_file(:doc)
          end

          create :upsert_with_doc do
            accept [:slug]
            upsert? true
            upsert_identity :unique_slug
            argument :doc, :file, allow_nil?: true

            change attach_file(:doc)
          end

          for name <- [:doc, :files, :fragile, :plain] do
            update :"update_#{name}" do
              require_atomic? false
              argument name, :file, allow_nil?: true

              change attach_file(name)
            end
          end

          create :create_with_doc_blob do
            accept [:slug]
            argument :doc_blob_id, :uuid, allow_nil?: true

            change attach_blob(:doc, argument: :doc_blob_id)
          end

          create :upsert_with_doc_blob do
            accept [:slug]
            upsert? true
            upsert_identity :unique_slug
            argument :doc_blob_id, :uuid, allow_nil?: true

            change attach_blob(:doc, argument: :doc_blob_id)
          end

          for name <- [:doc, :files, :fragile, :plain] do
            update :"update_#{name}_blob" do
              require_atomic? false
              argument :"#{name}_blob_id", :uuid, allow_nil?: true

              change attach_blob(name, argument: :"#{name}_blob_id")
            end
          end
        end
      end
    end
  end

  defp tenancy(nil), do: nil

  defp tenancy(:context) do
    quote do
      multitenancy do
        strategy :context
      end
    end
  end

  defp tenancy(:attribute) do
    quote do
      multitenancy do
        strategy :attribute
        attribute :org_id
      end
    end
  end

  defp org_id(:attribute) do
    quote do
      attribute :org_id, :uuid, allow_nil?: false, public?: true
    end
  end

  defp org_id(_multitenancy), do: nil

  defp storage_policies(nil), do: nil

  defp storage_policies(:actor) do
    quote do
      policies do
        policy always() do
          authorize_if actor_present()
        end
      end
    end
  end
end
