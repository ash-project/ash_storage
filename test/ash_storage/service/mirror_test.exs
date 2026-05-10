defmodule AshStorage.Service.MirrorTest do
  use ExUnit.Case, async: true

  alias AshStorage.Service.Context
  alias AshStorage.Service.Mirror
  alias AshStorage.Service.Test, as: TestService

  @primary_table :"#{__MODULE__}.Primary"
  @secondary_table :"#{__MODULE__}.Secondary"

  setup do
    services = [{TestService, name: @primary_table}, {TestService, name: @secondary_table}]
    {:ok, ctx: Context.new(services: services), services: services}
  end

  describe "upload/3" do
    test "writes to every child", %{ctx: ctx} do
      assert :ok == Mirror.upload("file.txt", "hello", ctx)

      assert TestService.exists?("file.txt", name: @primary_table)
      assert TestService.exists?("file.txt", name: @secondary_table)
    end

    test "returns {:ok, primary_attrs} when primary returns extra attrs" do
      defmodule PrimaryWithAttrs do
        @behaviour AshStorage.Service

        @impl true
        def upload(_, _, _), do: {:ok, %{encryption_key: "primary-key"}}
        @impl true
        def download(_, _), do: {:error, :not_found}
        @impl true
        def delete(_, _), do: :ok
        @impl true
        def exists?(_, _), do: {:ok, false}
        @impl true
        def url(_, _), do: ""
      end

      services = [
        {PrimaryWithAttrs, []},
        {TestService, name: @secondary_table}
      ]

      ctx = Context.new(services: services)

      assert {:ok, %{encryption_key: "primary-key"}} == Mirror.upload("file.txt", "hi", ctx)
    end

    test "halts and returns error if a child fails" do
      defmodule FailingChild do
        @behaviour AshStorage.Service

        @impl true
        def upload(_, _, _), do: {:error, :boom}
        @impl true
        def download(_, _), do: {:error, :not_found}
        @impl true
        def delete(_, _), do: :ok
        @impl true
        def exists?(_, _), do: {:ok, false}
        @impl true
        def url(_, _), do: ""
      end

      services = [
        {TestService, name: @primary_table},
        {FailingChild, []}
      ]

      ctx = Context.new(services: services)

      assert {:error, :boom} = Mirror.upload("file.txt", "hi", ctx)
      assert TestService.exists?("file.txt", name: @primary_table)
    end
  end

  describe "download/2" do
    test "reads from primary when present", %{ctx: ctx} do
      TestService.upload("file.txt", "primary-bytes", Context.new(name: @primary_table))
      TestService.upload("file.txt", "secondary-bytes", Context.new(name: @secondary_table))

      assert {:ok, "primary-bytes"} = Mirror.download("file.txt", ctx)
    end

    test "falls through to secondary on :not_found", %{ctx: ctx} do
      TestService.upload("file.txt", "secondary-bytes", Context.new(name: @secondary_table))

      assert {:ok, "secondary-bytes"} = Mirror.download("file.txt", ctx)
    end

    test "returns :not_found when no child has the file", %{ctx: ctx} do
      assert {:error, :not_found} = Mirror.download("missing.txt", ctx)
    end

    test "propagates non-not_found errors from primary" do
      defmodule ErroringPrimary do
        @behaviour AshStorage.Service

        @impl true
        def upload(_, _, _), do: :ok
        @impl true
        def download(_, _), do: {:error, :timeout}
        @impl true
        def delete(_, _), do: :ok
        @impl true
        def exists?(_, _), do: {:ok, false}
        @impl true
        def url(_, _), do: ""
      end

      services = [
        {ErroringPrimary, []},
        {TestService, name: @secondary_table}
      ]

      ctx = Context.new(services: services)
      assert {:error, :timeout} = Mirror.download("file.txt", ctx)
    end
  end

  describe "exists?/2" do
    test "falls through to secondary on miss", %{ctx: ctx} do
      TestService.upload("file.txt", "data", Context.new(name: @secondary_table))

      assert {:ok, true} == Mirror.exists?("file.txt", ctx)
    end

    test "returns {:ok, false} when no child has the file", %{ctx: ctx} do
      assert {:ok, false} == Mirror.exists?("missing.txt", ctx)
    end
  end

  describe "delete/2" do
    test "deletes from every child", %{ctx: ctx} do
      Mirror.upload("file.txt", "data", ctx)
      assert :ok == Mirror.delete("file.txt", ctx)

      refute TestService.exists?("file.txt", name: @primary_table)
      refute TestService.exists?("file.txt", name: @secondary_table)
    end

    test "halts on first child error" do
      defmodule FailingDelete do
        @behaviour AshStorage.Service

        @impl true
        def upload(_, _, _), do: :ok
        @impl true
        def download(_, _), do: {:error, :not_found}
        @impl true
        def delete(_, _), do: {:error, :forbidden}
        @impl true
        def exists?(_, _), do: {:ok, false}
        @impl true
        def url(_, _), do: ""
      end

      services = [
        {FailingDelete, []},
        {TestService, name: @secondary_table}
      ]

      ctx = Context.new(services: services)
      TestService.upload("file.txt", "data", Context.new(name: @secondary_table))

      assert {:error, :forbidden} = Mirror.delete("file.txt", ctx)
      assert TestService.exists?("file.txt", name: @secondary_table)
    end
  end

  describe "url/2 and direct_upload/2" do
    test "url/2 only consults the primary", %{ctx: ctx} do
      assert "http://test.local/storage/photo.jpg" == Mirror.url("photo.jpg", ctx)
    end

    test "direct_upload/2 only consults the primary", %{ctx: ctx} do
      assert {:ok, %{url: url, method: :put}} = Mirror.direct_upload("photo.jpg", ctx)
      assert url =~ "http://test.local/storage/direct/photo.jpg"
    end
  end

  describe "missing :services" do
    test "raises a clear error when context has no :services" do
      ctx = Context.new([])

      assert_raise ArgumentError, ~r/Mirror requires runtime configuration/, fn ->
        Mirror.download("file.txt", ctx)
      end
    end
  end

  describe "expand_sugar/1" do
    test "rewrites {Mod, [mirrors: [...]]} into a Mirror tuple" do
      input =
        {TestService,
         [
           name: :primary,
           mirrors: [{TestService, name: :backup_a}, {TestService, name: :backup_b}]
         ]}

      assert Mirror.expand_sugar(input) ==
               {Mirror,
                services: [
                  {TestService, [name: :primary]},
                  {TestService, name: :backup_a},
                  {TestService, name: :backup_b}
                ]}
    end

    test "is equivalent to writing the Mirror tuple directly" do
      sugar =
        Mirror.expand_sugar(
          {TestService, [name: :primary, mirrors: [{TestService, name: :backup}]]}
        )

      direct = {Mirror, services: [{TestService, [name: :primary]}, {TestService, name: :backup}]}

      assert sugar == direct
    end

    test "leaves tuples without :mirrors unchanged" do
      assert Mirror.expand_sugar({TestService, [name: :primary]}) ==
               {TestService, [name: :primary]}
    end

    test "treats an empty :mirrors list as a no-op" do
      assert Mirror.expand_sugar({TestService, [name: :primary, mirrors: []]}) ==
               {TestService, [name: :primary]}
    end

    test "preserves non-mirror keys in the primary's opts" do
      input =
        {AshStorage.Service.Disk,
         [root: "priv/storage", base_url: "/files", mirrors: [{TestService, name: :backup}]]}

      assert Mirror.expand_sugar(input) ==
               {Mirror,
                services: [
                  {AshStorage.Service.Disk, [root: "priv/storage", base_url: "/files"]},
                  {TestService, name: :backup}
                ]}
    end
  end
end
