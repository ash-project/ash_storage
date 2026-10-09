import Config

config :ash, :disable_async?, true
config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false
config :ash, :default_string_length_count, :codepoints

config :logger, level: :warning

if config_env() in [:test, :dev] do
  import_config "#{config_env()}.exs"
end
