defmodule AshStorage.PathTest do
  use ExUnit.Case, async: false

  alias AshStorage.Info
  alias AshStorage.Operations

  describe "resolve_key/3 with path" do
    test "uses custom path function when provided" do
      path_fn = fn _ctx, changeset ->
        org_id = changeset.context.tenant
        "#{org_id}/#{AshStorage.generate_key()}"
      end

      attachment_def = %AshStorage.AttachmentDefinition{
        name: :avatar,
        path: path_fn
      }

      ctx = AshStorage.Service.Context.new([])
      changeset = Ash.Changeset.for_create(AshStorage.Test.Post, :create, %{title: "test"})
      changeset = %{changeset | context: %{tenant: "org-123"}}

      key = AshStorage.resolve_key(attachment_def, ctx, changeset)
      assert String.starts_with?(key, "org-123/")
      refute key == "org-123/"
    end

    test "uses tenant when no custom path function is provided" do
      attachment_def = %AshStorage.AttachmentDefinition{
        name: :avatar
      }

      ctx = AshStorage.Service.Context.new([])
      changeset = Ash.Changeset.for_create(AshStorage.Test.Post, :create, %{title: "test"})
      changeset = %{changeset | tenant: "org-abc"}

      key = AshStorage.resolve_key(attachment_def, ctx, changeset)
      assert String.starts_with?(key, "org-abc")
    end

    test "able to also handle tenant struct" do
      tenant = Ash.create!(AshStorage.Test.Tenant, %{})

      attachment_def = %AshStorage.AttachmentDefinition{
        name: :avatar
      }

      ctx = AshStorage.Service.Context.new([])
      changeset = Ash.Changeset.for_create(AshStorage.Test.Post, :create, %{title: "test"})
      changeset = %{changeset | tenant: tenant}

      key = AshStorage.resolve_key(attachment_def, ctx, changeset)
      tenant_id = Ash.ToTenant.to_tenant(tenant, AshStorage.Test.Post)
      assert String.starts_with?(key, "#{tenant_id}/")
      refute key == "#{tenant_id}/"
    end

    test "falls back to a random key when no path is provided and no tenant present" do
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}
      ctx = AshStorage.Service.Context.new([])
      changeset = Ash.Changeset.for_create(AshStorage.Test.Post, :create, %{title: "test"})

      key = AshStorage.resolve_key(attachment_def, ctx, changeset)

      refute String.contains?(key, "/")
      assert byte_size(key) == 56
    end
  end

  describe "resolve_key_with_tenant/3 - no changeset" do
    test "uses tenant as part of the key when path is nil" do
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}

      key =
        AshStorage.resolve_key_with_tenant(attachment_def, "org-123", AshStorage.Test.PathPost)

      assert String.starts_with?(key, "org-123/")
      refute key == "org-123/"
    end

    test "able to use tenant struct" do
      tenant = Ash.create!(AshStorage.Test.Tenant, %{})
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}

      key =
        AshStorage.resolve_key_with_tenant(attachment_def, tenant, AshStorage.Test.PathPost)

      tenant_id = Ash.ToTenant.to_tenant(tenant, AshStorage.Test.PathPost)
      assert String.contains?(key, "#{tenant_id}/")
      refute key == "#{tenant_id}/"
    end

    test "returns just the key when path is nil and no tenant" do
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}

      key = AshStorage.resolve_key_with_tenant(attachment_def, nil, AshStorage.Test.PathPost)

      refute String.contains?(key, "/")
      assert byte_size(key) == 56
    end

    test "returns just key when tenant is empty string" do
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}

      key = AshStorage.resolve_key_with_tenant(attachment_def, "", AshStorage.Test.PathPost)

      refute String.contains?(key, "/")
      assert byte_size(key) == 56
    end
  end

  describe "resolve_variant_key/1" do
    test "preserves path from source blob key" do
      variant_key = AshStorage.resolve_variant_key("org-test/uuid")
      assert String.starts_with?(variant_key, "org-test/")
      refute(variant_key == "org-test/uuid")
    end

    test "preserves nested path from source blob key" do
      variant_key = AshStorage.resolve_variant_key("org-test/a/b/c/uuid")
      assert String.starts_with?(variant_key, "org-test/a/b/c/")
      refute(variant_key == "org-test/a/b/c/uuid")
    end

    test "returns just the key when source has no path" do
      variant_key = AshStorage.resolve_variant_key("uuid")
      refute String.contains?(variant_key, "/")
      assert byte_size(variant_key) == 56
    end
  end

  ## Integration tests

  describe "attach/4" do
    test "uses custom path from attachment definition" do
      post =
        AshStorage.Test.PathPost
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      assert {:ok, %{blob: blob}} =
               Operations.attach(post, :avatar, "avatar data",
                 filename: "avatar.png",
                 content_type: "image/png",
                 actor: %{org_id: "org-42"}
               )

      assert String.starts_with?(blob.key, "org-42/")
      assert AshStorage.Service.Test.exists?(blob.key)
    end

    test "uses tenant when there is no path specified" do
      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      assert {:ok, %{blob: blob}} =
               Operations.attach(post, :documents, "file data",
                 filename: "document.pdf",
                 content_type: "application/pdf",
                 tenant: "tenant-abc"
               )

      assert String.starts_with?(blob.key, "tenant-abc/")
    end

    test "without path or tenant" do
      post =
        AshStorage.Test.Post
        |> Ash.Changeset.for_create(:create, %{title: "test"})
        |> Ash.create!()

      assert {:ok, %{blob: blob}} =
               Operations.attach(post, :documents, "file data",
                 filename: "document.pdf",
                 content_type: "application/pdf"
               )

      refute String.starts_with?(blob.key, "/")
      assert byte_size(blob.key) == 56
    end
  end

  ## Integration tests: direct_upload
  describe "prepare_direct_upload" do
    test "with tenant" do
      {:ok, result} =
        Operations.prepare_direct_upload(AshStorage.Test.PathPost, :avatar,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 12_345,
          tenant: "tenant-42"
        )

      assert result.blob.filename == "photo.jpg"
      assert String.starts_with?(result.blob.key, "tenant-42/")
    end

    test "no tenant" do
      {:ok, result} =
        Operations.prepare_direct_upload(AshStorage.Test.PathPost, :avatar,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 12_345
        )

      assert result.blob.filename == "photo.jpg"
      refute String.contains?(result.blob.key, "/")
    end
  end

  ## Tests for attachment definitions
  describe "attachment definition path configuration" do
    test "specified path is stored in attachment definition" do
      {:ok, attachment_def} = Info.attachment(AshStorage.Test.PathPost, :avatar)

      assert attachment_def.path != nil
      assert is_function(attachment_def.path, 2)
    end

    test "attachment without path has no path definition" do
      {:ok, attachment_def} = Info.attachment(AshStorage.Test.Post, :cover_image)

      assert attachment_def.path == nil
    end
  end
end
