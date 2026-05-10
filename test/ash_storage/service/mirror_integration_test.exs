defmodule AshStorage.Service.MirrorIntegrationTest do
  use ExUnit.Case, async: false

  alias AshStorage.Service.Test, as: TestService
  alias AshStorage.Test.ConfigurablePost

  @sugar_primary :mirror_integration_primary
  @sugar_secondary :mirror_integration_secondary

  @explicit_primary :legacy_mirror_a
  @explicit_secondary :legacy_mirror_b

  @docs_primary :documents_mirror_a
  @docs_secondary :documents_mirror_b

  @all_named [
    @sugar_primary,
    @sugar_secondary,
    @explicit_primary,
    @explicit_secondary,
    @docs_primary,
    @docs_secondary
  ]

  @opts [filename: "doc.txt", content_type: "text/plain"]

  setup do
    TestService.start()
    TestService.reset!()

    for name <- @all_named do
      TestService.start(name: name)
      TestService.reset!(name: name)
    end

    :ok
  end

  describe "has_one_attached with the :mirrors sugar (:mirrored_avatar)" do
    test "attach fans the upload out to the primary and every mirror" do
      post = create_post("sugar-attach")

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :mirrored_avatar, "mirrored payload", @opts)

      assert {:ok, "mirrored payload"} = TestService.download(blob.key, [])
      assert {:ok, "mirrored payload"} = TestService.download(blob.key, name: @sugar_primary)
      assert {:ok, "mirrored payload"} = TestService.download(blob.key, name: @sugar_secondary)

      # the explicit-form mirror tables are isolated from this attachment
      refute TestService.exists?(blob.key, name: @explicit_primary)
      refute TestService.exists?(blob.key, name: @explicit_secondary)
    end

    test "purge fans the delete out to every backend" do
      post = create_post("sugar-purge")

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :mirrored_avatar, "soon to be deleted", @opts)

      {:ok, _} = AshStorage.Operations.purge(post, :mirrored_avatar)

      refute TestService.exists?(blob.key, [])
      refute TestService.exists?(blob.key, name: @sugar_primary)
      refute TestService.exists?(blob.key, name: @sugar_secondary)
    end
  end

  describe "has_one_attached with the explicit Mirror form (:legacy_mirror_avatar)" do
    test "attach fans the upload out to the primary and every mirror" do
      post = create_post("explicit-attach")

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :legacy_mirror_avatar, "explicit payload", @opts)

      assert {:ok, "explicit payload"} = TestService.download(blob.key, [])
      assert {:ok, "explicit payload"} = TestService.download(blob.key, name: @explicit_primary)
      assert {:ok, "explicit payload"} = TestService.download(blob.key, name: @explicit_secondary)

      # the sugar-form mirror tables are isolated from this attachment
      refute TestService.exists?(blob.key, name: @sugar_primary)
      refute TestService.exists?(blob.key, name: @sugar_secondary)
    end

    test "purge fans the delete out to every backend" do
      post = create_post("explicit-purge")

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(
          post,
          :legacy_mirror_avatar,
          "soon to be deleted",
          @opts
        )

      {:ok, _} = AshStorage.Operations.purge(post, :legacy_mirror_avatar)

      refute TestService.exists?(blob.key, [])
      refute TestService.exists?(blob.key, name: @explicit_primary)
      refute TestService.exists?(blob.key, name: @explicit_secondary)
    end

    test "the bare :avatar attachment still writes only to the default backend" do
      post = create_post("isolation")

      {:ok, %{blob: blob}} =
        AshStorage.Operations.attach(post, :avatar, "plain payload", @opts)

      assert {:ok, "plain payload"} = TestService.download(blob.key, [])

      for name <- @all_named do
        refute TestService.exists?(blob.key, name: name),
               "expected :avatar to skip mirror table #{inspect(name)}"
      end
    end
  end

  describe "has_many_attached with the :mirrors sugar (:mirrored_documents)" do
    test "each attached document fans out to the primary and every mirror" do
      post = create_post("docs-attach")

      {:ok, %{blob: blob_one}} =
        AshStorage.Operations.attach(post, :mirrored_documents, "doc one", @opts)

      {:ok, %{blob: blob_two}} =
        AshStorage.Operations.attach(post, :mirrored_documents, "doc two", @opts)

      for {blob, payload} <- [{blob_one, "doc one"}, {blob_two, "doc two"}] do
        assert {:ok, ^payload} = TestService.download(blob.key, [])
        assert {:ok, ^payload} = TestService.download(blob.key, name: @docs_primary)
        assert {:ok, ^payload} = TestService.download(blob.key, name: @docs_secondary)
      end
    end

    test "purge :all removes every attached document from every backend" do
      post = create_post("docs-purge")

      {:ok, %{blob: blob_one}} =
        AshStorage.Operations.attach(post, :mirrored_documents, "doc one", @opts)

      {:ok, %{blob: blob_two}} =
        AshStorage.Operations.attach(post, :mirrored_documents, "doc two", @opts)

      {:ok, _} = AshStorage.Operations.purge(post, :mirrored_documents, all: true)

      for blob <- [blob_one, blob_two], name <- [nil, @docs_primary, @docs_secondary] do
        opts = if name, do: [name: name], else: []

        refute TestService.exists?(blob.key, opts),
               "blob #{blob.key} should be gone from #{inspect(name)}"
      end
    end
  end

  defp create_post(title) do
    ConfigurablePost
    |> Ash.Changeset.for_create(:create, %{title: title})
    |> Ash.create!()
  end
end
