import Config

config :ash, :disable_async?, true
config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false

config :logger, level: :warning
