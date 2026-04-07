defmodule Mix.Tasks.AshStorage.Install.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc do
    "Installs AshStorage. Creates blob and attachment resources."
  end

  @spec example() :: String.t()
  def example do
    "mix igniter.install ash_storage"
  end

  @spec long_doc() :: String.t()
  def long_doc do
    """
    #{short_doc()}

    Creates a blob resource and an attachment resource, and configures the formatter.

    ## Example

    ```sh
    #{example()}
    ```

    ## Options

    * `--domain` - The domain module for storage resources (default: `YourApp.Storage`)
    * `--blob` - The module name for the blob resource (default: `YourApp.Storage.Blob`)
    * `--attachment` - The module name for the attachment resource (default: `YourApp.Storage.Attachment`)
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshStorage.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        adds_deps: [],
        installs: [],
        example: __MODULE__.Docs.example(),
        only: nil,
        positional: [],
        composes: [],
        schema: [
          domain: :string,
          blob: :string,
          attachment: :string
        ],
        defaults: [],
        aliases: [],
        required: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options

      domain_module =
        case opts[:domain] do
          nil -> Igniter.Project.Module.module_name(igniter, "Storage")
          name -> Igniter.Project.Module.parse(name)
        end

      blob_module =
        case opts[:blob] do
          nil -> Module.concat(domain_module, "Blob")
          name -> Igniter.Project.Module.parse(name)
        end

      attachment_module =
        case opts[:attachment] do
          nil -> Module.concat(domain_module, "Attachment")
          name -> Igniter.Project.Module.parse(name)
        end

      repo = Igniter.Project.Module.module_name(igniter, "Repo")

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_storage)
      |> create_domain(domain_module)
      |> create_blob_resource(blob_module, repo, domain_module)
      |> create_attachment_resource(attachment_module, blob_module, repo, domain_module)
      |> Igniter.add_notice("""
      AshStorage installed!

      Resources created:
        * #{inspect(blob_module)}
        * #{inspect(attachment_module)}

      Next steps:

        1. Add `belongs_to_resource` entries to #{inspect(attachment_module)}
           for each resource that will have attachments:

            attachment do
              blob_resource #{inspect(blob_module)}
              belongs_to_resource :post, MyApp.Post
            end

        2. Add `AshStorage` to your host resource:

            use Ash.Resource, extensions: [AshStorage]

            storage do
              service {AshStorage.Service.Disk, root: "priv/storage", base_url: "/storage"}
              blob_resource #{inspect(blob_module)}
              attachment_resource #{inspect(attachment_module)}

              has_one_attached :avatar
            end

        3. Generate and run migrations:

            mix ash.codegen add_storage
      """)
    end

    defp create_domain(igniter, domain_module) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, domain_module)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, domain_module, """
          use Ash.Domain

          resources do
          end
        """)
      end
    end

    defp create_blob_resource(igniter, blob_module, repo, domain_module) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, blob_module)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, blob_module, """
          use Ash.Resource,
            domain: #{inspect(domain_module)},
            data_layer: AshPostgres.DataLayer,
            extensions: [AshStorage.BlobResource]

          postgres do
            table "storage_blobs"
            repo #{inspect(repo)}
          end

          attributes do
            uuid_primary_key :id
          end
        """)
      end
    end

    defp create_attachment_resource(igniter, attachment_module, blob_module, repo, domain_module) do
      {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, attachment_module)

      if exists? do
        igniter
      else
        Igniter.Project.Module.create_module(igniter, attachment_module, """
          use Ash.Resource,
            domain: #{inspect(domain_module)},
            data_layer: AshPostgres.DataLayer,
            extensions: [AshStorage.AttachmentResource]

          postgres do
            table "storage_attachments"
            repo #{inspect(repo)}
          end

          attachment do
            blob_resource #{inspect(blob_module)}
          end

          attributes do
            uuid_primary_key :id
          end
        """)
      end
    end
  end
else
  defmodule Mix.Tasks.AshStorage.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_storage.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
