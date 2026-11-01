import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :good_flows, GoodFlows.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "good_flows_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :good_flows, GoodFlowsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "WOfQglvaxzm4BnsDuxAim8osKhtzkaIagyoNYnJxtNd9wVZq2jGcTRq3X41iKb0u",
  server: false

# Fixed encryption key for tests only.
config :good_flows, GoodFlows.Vault, key: "OItCtf1i+OuEvu0P7Ik+csu7g7Rx1cO0Jz/7NNwFjwk="

# Short Spry deadlines so timeout tests run quickly.
config :good_flows, GoodFlows.Spry,
  step_timeout_ms: 300,
  run_timeout_ms: 1_500,
  output_limit_bytes: 65_536,
  # Unroutable so a test that misses a stub can never reach the real API.
  sprites_base_url: "http://127.0.0.1:9"

# In test we don't send emails
config :good_flows, GoodFlows.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
