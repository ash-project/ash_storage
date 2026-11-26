defmodule AshStorage.BuiltinsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AshStorage.Changes.Builtins
  alias AshStorage.Verifiers.ValidateAttachChanges

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule BuiltinPost do
    @moduledoc false
    use Ash.Resource,
      domain: AshStorage.BuiltinsTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshStorage]

    ets do
      private? true
    end

    storage do
      service({AshStorage.Service.Test, []})
      blob_resource(AshStorage.Test.Blob)
      attachment_resource(AshStorage.Test.PolymorphicAttachment)

      has_one_attached(:cover)
    end

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]

      create :create do
        primary? true
        argument :cover, :file, allow_nil?: true
        change attach_file(:cover)
      end

      create :create_from_blob do
        argument :cover_blob_id, :uuid, allow_nil?: true
        change attach_blob(:cover, argument: :cover_blob_id)
      end
    end

    code_interface do
      define :attach_blob, action: :create_from_blob, args: [:cover_blob_id]
    end
  end

  setup do
    AshStorage.Service.Test.reset!()
    :ok
  end

  describe "attach_file/2 and attach_blob/2" do
    test "build the change, with the argument defaulting to the attachment's name" do
      assert Builtins.attach_file(:cover) ==
               {AshStorage.Changes.AttachFileArgument, argument: :cover, attachment: :cover}

      assert Builtins.attach_file(:cover, argument: :upload) ==
               {AshStorage.Changes.AttachFileArgument, argument: :upload, attachment: :cover}

      assert Builtins.attach_blob(:cover) ==
               {AshStorage.Changes.AttachBlob, argument: :cover, attachment: :cover}

      assert Builtins.attach_blob(:cover, argument: :cover_blob_id) ==
               {AshStorage.Changes.AttachBlob, argument: :cover_blob_id, attachment: :cover}
    end

    test "refuse any other option" do
      assert_raise ArgumentError, ~r/unknown option :bogus for attach_file\/2/, fn ->
        Builtins.attach_file(:cover, bogus: 1)
      end

      assert_raise ArgumentError, ~r/attach_blob\/2/, fn ->
        Builtins.attach_blob(:cover, argument: "cover")
      end

      assert_raise ArgumentError, ~r/attachment's name/, fn -> Builtins.attach_file("cover") end
    end
  end

  describe "a resource using them without an import" do
    test "has the changes in its actions" do
      changes =
        for name <- [:create, :create_from_blob] do
          [change] = Ash.Resource.Info.action(BuiltinPost, name).changes
          change.change
        end

      assert changes == [
               Builtins.attach_file(:cover),
               Builtins.attach_blob(:cover, argument: :cover_blob_id)
             ]
    end

    test "attaches a file on create" do
      path = Path.join(System.tmp_dir!(), "ash_storage_builtins_test.txt")
      File.write!(path, "hello")

      post = Ash.create!(BuiltinPost, %{cover: Ash.Type.File.from_path(path)})

      assert Ash.load!(post, cover: :blob).cover.blob.id == post.__metadata__[:cover_blob].id
    after
      File.rm(Path.join(System.tmp_dir!(), "ash_storage_builtins_test.txt"))
    end

    test "keeps a code interface function with the same name" do
      {:ok, %{blob: blob}} =
        AshStorage.Operations.prepare_direct_upload(BuiltinPost, :cover, filename: "c.txt")

      :ok = AshStorage.Service.Test.upload(blob.key, "c", AshStorage.Service.Context.new([]))

      assert %BuiltinPost{} = post = BuiltinPost.attach_blob!(blob.id)
      assert post.__metadata__[:cover_blob].id == blob.id
    end
  end

  describe "the verifier" do
    test "rejects an attachment the resource does not declare" do
      error =
        verify_error(:unknown_attachment, "change attach_file(:nope)", "argument :nope, :file")

      assert error.path == [:actions, :create]
      assert error.message =~ ":nope"
      assert error.message =~ ":create"
    end

    test "names the replacement of a removed file-argument change" do
      for {name, change} <- [
            removed_tuple:
              "change {AshStorage.Changes.HandleFileArgument, argument: :cover, attachment: :cover}",
            removed_module: "change AshStorage.Changes.AttachFile"
          ] do
        error = verify_error(name, change, "argument :cover, :file")

        assert error.path == [:actions, :create]
        assert error.message =~ "was removed"
        assert error.message =~ "attach_file/2"
      end

      refute Code.ensure_loaded?(AshStorage.Changes.HandleFileArgument)
      refute Code.ensure_loaded?(AshStorage.Changes.AttachFile)
    end

    test "passes actions whose validations sit next to an attach change" do
      module =
        compile_post(:validated, """
        create :create do
          accept [:title]
          argument :cover, :file, allow_nil?: true
          validate present(:title)
          change attach_file(:cover)
        end

        update :update do
          require_atomic? false
          accept [:title]
          argument :cover, :file, allow_nil?: true
          validate present(:title)
          change attach_file(:cover)
        end
        """)

      assert :ok = ValidateAttachChanges.verify(module.spark_dsl_config())
    end

    test "rejects an argument the action does not have" do
      error = verify_error(:missing_argument, "change attach_file(:cover)", "")

      assert error.path == [:actions, :create]
      assert error.message =~ "argument :cover"
    end
  end

  # Compiles a resource whose create action has `change` and `argument`, and
  # runs the verifier on it. Spark prints a verifier's error as a warning once
  # the module is compiled, so the output is captured here and the verifier is
  # called directly.
  defp verify_error(name, change, argument) do
    module =
      compile_post(name, """
      create :create do
        #{argument}
        #{change}
      end
      """)

    assert {:error, %Spark.Error.DslError{} = error} =
             ValidateAttachChanges.verify(module.spark_dsl_config())

    error
  end

  defp compile_post(name, actions) do
    module = Module.concat(__MODULE__, Macro.camelize("#{name}_post"))

    capture_io(:stderr, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Ash.Resource,
          domain: AshStorage.BuiltinsTest.Domain,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshStorage]

        storage do
          service({AshStorage.Service.Test, []})
          blob_resource(AshStorage.Test.Blob)
          attachment_resource(AshStorage.Test.PolymorphicAttachment)

          has_one_attached(:cover)
        end

        attributes do
          uuid_primary_key :id
          attribute :title, :string, public?: true
        end

        actions do
          #{actions}
        end
      end
      """)
    end)

    module
  end
end
