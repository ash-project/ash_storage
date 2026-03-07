defmodule AshStorage.MixProject do
  use Mix.Project

  @description """
  An Ash extension for file storage, attachments, and variants.
  """

  @version "0.1.0"

  @source_url "https://github.com/ash-project/ash_storage"

  def project do
    [
      app: :ash_storage,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      package: package(),
      aliases: aliases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [plt_add_apps: [:ash, :mix]],
      docs: &docs/0,
      description: @description,
      source_url: @source_url,
      homepage_url: "https://github.com/ash-project/ash_storage"
    ]
  end

  defp elixirc_paths(:test) do
    elixirc_paths(:dev) ++ ["test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extra_section: "GUIDES",
      before_closing_head_tag: fn type ->
        if type == :html do
          """
          <script>
            if (location.hostname === "hexdocs.pm") {
              var script = document.createElement("script");
              script.src = "https://plausible.io/js/script.js";
              script.setAttribute("defer", "defer")
              script.setAttribute("data-domain", "ashhexdocs")
              document.head.appendChild(script);
            }
          </script>
          """
        end
      end,
      extras: [
        {"README.md", title: "Home"},
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Tutorials: ~r'documentation/tutorials',
        "How To": ~r'documentation/how_to',
        Topics: ~r'documentation/topics',
        DSLs: ~r'documentation/dsls',
        "About AshStorage": [
          "CHANGELOG.md"
        ]
      ],
      groups_for_modules: [
        AshStorage: [
          AshStorage,
          AshStorage.Operations
        ],
        "DSL Extensions": [
          AshStorage.Resource,
          AshStorage.BlobResource,
          AshStorage.AttachmentResource
        ],
        Services: [
          AshStorage.Service,
          AshStorage.Service.Disk,
          AshStorage.Service.S3,
          AshStorage.Service.Test
        ],
        Plugs: [
          AshStorage.Plug.DiskServe,
          AshStorage.Plug.Proxy
        ],
        Utilities: [
          AshStorage.Token
        ],
        Introspection: [
          AshStorage.Resource.Info,
          AshStorage.Resource.AttachmentDefinition
        ]
      ]
    ]
  end

  defp package do
    [
      maintainers: [
        "Zach Daniel <zach@zachdaniel.dev>"
      ],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      links: %{
        "GitHub" => @source_url,
        "Discord" => "https://discord.gg/HTHRaaVPUc",
        "Website" => "https://ash-hq.org",
        "Forum" => "https://elixirforum.com/c/ash-framework-forum/",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ash, ash_version("~> 3.5")},
      {:spark, "~> 2.2 and >= 2.2.10"},
      {:igniter, "~> 0.5", optional: true},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.14", optional: true},
      {:plug_crypto, "~> 1.2 or ~> 2.0", optional: true},
      {:mime, "~> 2.0", optional: true},
      {:req, "~> 0.5", optional: true},
      {:req_s3, "~> 0.2", optional: true},
      # dev/test dependencies
      {:ex_doc, "~> 0.37-rc", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.12", only: [:dev, :test]},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.5", only: [:dev, :test]},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false},
      {:simple_sat, ">= 0.0.0", only: :test},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp ash_version(default_version) do
    case System.get_env("ASH_VERSION") do
      nil -> default_version
      "local" -> [path: "../ash"]
      "main" -> [git: "https://github.com/ash-project/ash.git"]
      version -> "~> #{version}"
    end
  end

  defp aliases do
    [
      sobelow: "sobelow --skip",
      credo: "credo --strict",
      docs: [
        "docs",
        "spark.replace_doc_links"
      ]
    ]
  end
end
