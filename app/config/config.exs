# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :good_flows, :scopes,
  user: [
    default: true,
    module: GoodFlows.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: GoodFlows.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :good_flows,
  ecto_repos: [GoodFlows.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :good_flows, GoodFlowsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GoodFlowsWeb.ErrorHTML, json: GoodFlowsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GoodFlows.PubSub,
  live_view: [signing_salt: "JEK2fGe/"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Spry runs. The PgFlow job timeout (GoodFlows.Spry.Config.job_timeout_seconds/0)
# must cover run_timeout_ms plus 5 minutes; this is checked at startup.
config :good_flows, GoodFlows.Spry,
  step_timeout_ms: 30 * 60_000,
  run_timeout_ms: 6 * 60 * 60_000,
  output_limit_bytes: 65_536,
  sprites_base_url: nil

# Remote cache storage (GoodFlows.Caches). Caches are disabled until a bucket
# is configured; config/runtime.exs reads CACHE_S3_* and the CACHE_* limits.
config :good_flows, GoodFlows.Caches.ObjectStore,
  adapter: GoodFlows.Caches.ObjectStore.S3,
  bucket: nil

config :good_flows,
  cache_max_entry_bytes: 5_000_000_000,
  cache_project_quota_bytes: 53_687_091_200,
  cache_project_max_entries: 10_000,
  cache_max_keys_per_project: 1_000,
  cache_retention_days: 7,
  cache_reservation_ttl_seconds: 7_200,
  cache_upload_url_ttl_seconds: 900,
  cache_download_url_ttl_seconds: 900

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :good_flows, GoodFlows.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  good_flows: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  good_flows: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Keep secrets out of request logs: the Sprites token arrives as a "token"
# param on PUT /api/v1/sprites-credential. Matches any param containing a term.
# (Test report bodies never become params: the endpoint does not parse that
# route, see GoodFlowsWeb.Plugs.BodyParsers.)
config :phoenix, :filter_parameters, ["password", "token"]

# Test report upload limits (POST /api/v1/projects/:project/test-reports) are
# runtime settings: see config/runtime.exs and .env.sample.

# Repo for enqueue without a running PgFlow supervisor (tests).
config :pgflow, repo: GoodFlows.Repo

# Sentry error tracking. Events are only sent when SENTRY_DSN is set (runtime.exs).
config :sentry,
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  # The Sprites SDK keeps the account token in its process state; scrub it
  # from crash reports before they leave the app.
  before_send: {GoodFlows.Spry.Redaction, :sentry_before_send}

# Attach Sentry to Elixir's Logger so crashes/errors are captured automatically
config :good_flows, :logger, [
  {:handler, :sentry_handler, Sentry.LoggerHandler, %{config: %{metadata: [:request_id]}}}
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
