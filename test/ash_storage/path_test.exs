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

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, changeset)
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

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, changeset)
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

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, changeset)
      tenant_id = Ash.ToTenant.to_tenant(tenant, AshStorage.Test.Post)
      assert String.starts_with?(key, "#{tenant_id}/")
      refute key == "#{tenant_id}/"
    end

    test "falls back to a random key when no path is provided and no tenant present" do
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}
      ctx = AshStorage.Service.Context.new([])
      changeset = Ash.Changeset.for_create(AshStorage.Test.Post, :create, %{title: "test"})

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, changeset)

      refute String.contains?(key, "/")
      assert byte_size(key) == 56
    end
  end

  describe "resolve_key/3 without a changeset" do
    test "calls the path function with a nil changeset" do
      attachment_def = %AshStorage.AttachmentDefinition{
        name: :avatar,
        path: fn ctx, nil -> "#{ctx.tenant}/products/#{AshStorage.generate_key()}" end
      }

      ctx = AshStorage.Service.Context.new([], tenant: "org-123")

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, nil)

      assert String.starts_with?(key, "org-123/products/")
      refute key == "org-123/products/"
    end

    test "uses tenant from the context as part of the key when path is nil" do
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}

      ctx =
        AshStorage.Service.Context.new([], tenant: "org-123", resource: AshStorage.Test.PathPost)

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, nil)

      assert String.starts_with?(key, "org-123/")
      refute key == "org-123/"
    end

    test "able to use tenant struct" do
      tenant = Ash.create!(AshStorage.Test.Tenant, %{})
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}
      ctx = AshStorage.Service.Context.new([], tenant: tenant, resource: AshStorage.Test.PathPost)

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, nil)

      tenant_id = Ash.ToTenant.to_tenant(tenant, AshStorage.Test.PathPost)
      assert String.starts_with?(key, "#{tenant_id}/")
      refute key == "#{tenant_id}/"
    end

    test "returns just the key when path is nil and no tenant" do
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}
      ctx = AshStorage.Service.Context.new([], resource: AshStorage.Test.PathPost)

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, nil)

      refute String.contains?(key, "/")
      assert byte_size(key) == 56
    end

    test "returns just key when tenant is empty string" do
      attachment_def = %AshStorage.AttachmentDefinition{name: :avatar}
      ctx = AshStorage.Service.Context.new([], tenant: "", resource: AshStorage.Test.PathPost)

      {:ok, key} = AshStorage.resolve_key(attachment_def, ctx, nil)

      refute String.contains?(key, "/")
      assert byte_size(key) == 56
    end
  end

  describe "resolve_key/3 validation" do
    defp definition(path), do: %AshStorage.AttachmentDefinition{name: :avatar, path: path}

    test "a key from a path function must follow the key rules" do
      ctx = AshStorage.Service.Context.new([])

      for {key, reason} <- [
            {"../etc/passwd", :parent_segment},
            {"/etc/passwd", :absolute},
            {"a//b", :empty_segment},
            {"a/", :trailing_slash},
            {"a\\b", :invalid_character},
            {"my photo.png", :invalid_character},
            {"", :empty},
            {nil, :not_a_binary}
          ] do
        assert AshStorage.resolve_key(definition(fn _, _ -> key end), ctx, nil) ==
                 {:error, {:invalid_storage_key, reason, key}}
      end
    end

    test "a path function may use a tenant that contains a slash" do
      ctx = AshStorage.Service.Context.new([], tenant: "acme/eu")
      path = fn ctx, _ -> "#{ctx.tenant}/#{AshStorage.generate_key()}" end

      assert {:ok, "acme/eu/" <> _} = AshStorage.resolve_key(definition(path), ctx, nil)
    end

    test "the tenant prefix is the tenant, one slash and a generated key" do
      ctx = AshStorage.Service.Context.new([], tenant: "org-123", resource: AshStorage.Test.Post)

      assert {:ok, "org-123/" <> generated} = AshStorage.resolve_key(definition(nil), ctx, nil)
      assert generated =~ ~r/\A[0-9a-f]{56}\z/
    end

    test "a tenant that cannot be one key segment is rejected" do
      for {tenant, reason} <- [
            {"acme/eu", :separator},
            {"acme/", :separator},
            {"..", :parent_segment},
            {".", :dot_segment},
            {"acme\\eu", :invalid_character},
            {"acme\neu", :invalid_character},
            {"org:123", :invalid_character},
            {"jane@example.com", :invalid_character}
          ] do
        ctx = AshStorage.Service.Context.new([], tenant: tenant, resource: AshStorage.Test.Post)

        assert AshStorage.resolve_key(definition(nil), ctx, nil) ==
                 {:error, {:invalid_storage_key, {:tenant, reason}, tenant}}

        changeset = Ash.Changeset.for_create(AshStorage.Test.Post, :create, %{title: "test"})
        changeset = %{changeset | tenant: tenant}

        assert AshStorage.resolve_key(
                 definition(nil),
                 AshStorage.Service.Context.new([]),
                 changeset
               ) ==
                 {:error, {:invalid_storage_key, {:tenant, reason}, tenant}}
      end
    end

    test "a tenant that is not a string is converted before it is checked" do
      ctx = AshStorage.Service.Context.new([], tenant: 42, resource: AshStorage.Test.Post)

      assert {:ok, "42/" <> _} = AshStorage.resolve_key(definition(nil), ctx, nil)
    end
  end

  describe "resolve_variant_key/1 validation" do
    test "a source key that breaks the rules gives no variant key" do
      for {source, reason} <- [
            {"legacy\\dir/uuid", :invalid_character},
            {"org:123/uuid", :invalid_character},
            {"/absolute/uuid", :absolute},
            {"/uuid", :absolute},
            {"../up/uuid", :parent_segment},
            {"a//uuid", :empty_segment}
          ] do
        assert {:error, {:invalid_storage_key, ^reason, key}} =
                 AshStorage.resolve_variant_key(source)

        directory = source |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
        assert String.starts_with?(key, directory <> "/")
      end
    end

    test "a source key that breaks a rule only in its last segment still gets a variant key" do
      assert {:ok, key} = AshStorage.resolve_variant_key("legacy\\uuid")
      refute String.contains?(key, "/")

      assert {:ok, "dir/" <> _} = AshStorage.resolve_variant_key("dir/bad\\name")
      assert {:ok, "dir/" <> _} = AshStorage.resolve_variant_key("dir/my photo.png")
    end
  end

  describe "resolve_variant_key/1" do
    test "preserves path from source blob key" do
      {:ok, variant_key} = AshStorage.resolve_variant_key("org-test/uuid")
      assert String.starts_with?(variant_key, "org-test/")
      refute(variant_key == "org-test/uuid")
    end

    test "preserves nested path from source blob key" do
      {:ok, variant_key} = AshStorage.resolve_variant_key("org-test/a/b/c/uuid")
      assert String.starts_with?(variant_key, "org-test/a/b/c/")
      refute(variant_key == "org-test/a/b/c/uuid")
    end

    test "returns just the key when source has no path" do
      {:ok, variant_key} = AshStorage.resolve_variant_key("uuid")
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
    test "uses custom path from attachment definition" do
      {:ok, result} =
        Operations.prepare_direct_upload(AshStorage.Test.PathPost, :avatar,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 12_345,
          actor: %{org_id: "org-42"},
          tenant: "tenant-42"
        )

      assert result.blob.filename == "photo.jpg"
      assert String.starts_with?(result.blob.key, "org-42/")
      assert result.url =~ "/direct/org-42/"
    end

    test "uses tenant when there is no path specified" do
      {:ok, result} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 12_345,
          tenant: "tenant-42"
        )

      assert result.blob.filename == "photo.jpg"
      assert String.starts_with?(result.blob.key, "tenant-42/")
    end

    test "without path or tenant" do
      {:ok, result} =
        Operations.prepare_direct_upload(AshStorage.Test.Post, :cover_image,
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
