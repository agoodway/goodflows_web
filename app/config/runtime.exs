import Config

# Load .env file for development and test environments
# In production, environment variables should be set by the deployment platform
if config_env() in [:dev, :test] do
  env_files = [
    ".env.#{config_env()}.local",
    ".env.#{config_env()}",
    ".env.local",
    ".env"
  ]

  existing_files = Enum.filter(env_files, &File.exists?/1)

  env_vars =
    existing_files
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn file, acc ->
      case Dotenvy.source(file) do
        {:ok, vars} -> Map.merge(acc, vars)
        _ -> acc
      end
    end)

  Enum.each(env_vars, fn {key, value} ->
    if is_nil(System.get_env(key)) do
      System.put_env(key, value)
    end
  end)
end

# Worktrees get their own databases via BRANCH_DB (written to .env.*.local by
# scripts/setup_branch_db.sh). Explicit test prefixes and partition suffixes
# must override saved branch settings.
if config_env() in [:dev, :test] do
  branch = System.get_env("BRANCH_DB")

  if branch && !Regex.match?(~r/\A[a-zA-Z0-9_]{1,24}\z/, branch) do
    raise "BRANCH_DB must contain 1 to 24 letters, digits or underscores"
  end

  database =
    if branch,
      do: "good_flows_#{branch}_#{config_env()}",
      else: "good_flows_#{config_env()}"

  database =
    if config_env() == :test,
      do:
        (System.get_env("TEST_DATABASE_PREFIX") || database) <>
          (System.get_env("MIX_TEST_PARTITION") || ""),
      else: database

  config :good_flows, GoodFlows.Repo, database: database
end

# Sentry error tracking
if sentry_dsn = System.get_env("SENTRY_DSN") do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: config_env()
end

# Encryption key for data at rest (GoodFlows.Vault). Required in production;
# dev and test fall back to the fixed keys in dev.exs / test.exs.
case {config_env(), System.get_env("CLOAK_KEY")} do
  {:prod, key} when key in [nil, ""] ->
    raise """
    environment variable CLOAK_KEY is missing.
    Generate one with: elixir -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())'
    """

  {:test, _key} ->
    :ok

  {_env, key} when key in [nil, ""] ->
    :ok

  {_env, key} ->
    config :good_flows, GoodFlows.Vault, key: key
end

# Single source for non-test boots (dev + prod + releases). Omitted in test
# so GoodFlows.Application does not start PgFlow workers.
if config_env() != :test do
  config :good_flows, PgFlow,
    repo: GoodFlows.Repo,
    jobs: [
      GoodFlows.Spry.RunJob,
      GoodFlows.Spry.ReapRunsJob,
      GoodFlows.Pools.ProvisionMemberJob,
      GoodFlows.Pools.ResetMemberJob,
      GoodFlows.Pools.DestroyMemberJob
    ],
    flows: [],
    max_concurrency: 10,
    # Explicit per-job limits: at most this many Spry runs execute at once on
    # each node (queued runs wait for capacity; the reaper only fails a queued
    # run once its PgFlow job is gone), and a single reaper sweep at a time.
    worker_options: %{
      GoodFlows.Spry.RunJob => [
        max_concurrency: String.to_integer(System.get_env("SPRY_RUN_MAX_CONCURRENCY", "10"))
      ],
      GoodFlows.Spry.ReapRunsJob => [max_concurrency: 1],
      # Long pool setups run in their own worker pools so they cannot starve
      # RunJob.
      GoodFlows.Pools.ProvisionMemberJob => [
        max_concurrency: String.to_integer(System.get_env("POOL_PROVISION_MAX_CONCURRENCY", "4"))
      ],
      GoodFlows.Pools.ResetMemberJob => [
        max_concurrency: String.to_integer(System.get_env("POOL_RESET_MAX_CONCURRENCY", "4"))
      ],
      GoodFlows.Pools.DestroyMemberJob => [
        max_concurrency: String.to_integer(System.get_env("POOL_DESTROY_MAX_CONCURRENCY", "2"))
      ]
    },
    signal_strategy: :notify
end

# Test report uploads (POST /api/v1/projects/:project/test-reports), read at
# call time. Each admitted upload holds at most one Repo connection at a
# time, so the node cap must stay well below POOL_SIZE (checked in prod).
# Test keeps the values from config/test.exs.
if config_env() != :test do
  env_int = fn name, default -> String.to_integer(System.get_env(name, default)) end

  config :good_flows,
    test_report_max_body_bytes: env_int.("TEST_REPORT_MAX_BODY_BYTES", "33554432"),
    test_report_max_concurrent_uploads: env_int.("TEST_REPORT_MAX_CONCURRENT_UPLOADS", "2"),
    test_report_max_concurrent_uploads_per_account:
      env_int.("TEST_REPORT_MAX_CONCURRENT_UPLOADS_PER_ACCOUNT", "1"),
    test_report_read_timeout_ms: env_int.("TEST_REPORT_READ_TIMEOUT_MS", "60000"),
    test_report_max_heap_bytes: env_int.("TEST_REPORT_MAX_HEAP_BYTES", "2147483648"),
    test_report_db_timeout_ms: env_int.("TEST_REPORT_DB_TIMEOUT_MS", "15000")
end

# Sprite pools (GoodFlows.Pools.Config documents every key). Test keeps the
# values from config/test.exs.
if config_env() != :test do
  env_int = fn name, default -> String.to_integer(System.get_env(name, default)) end

  config :good_flows, GoodFlows.Pools,
    enabled: System.get_env("POOLS_ENABLED", "true") not in ["false", "0"],
    max_members_cap: env_int.("POOL_MAX_MEMBERS_CAP", "32"),
    provision_timeout_ms: env_int.("POOL_PROVISION_TIMEOUT_MS", "1800000"),
    workspace_max_bytes: env_int.("POOL_WORKSPACE_MAX_BYTES", "268435456"),
    workspace_max_expanded_bytes: env_int.("POOL_WORKSPACE_MAX_EXPANDED_BYTES", "2147483648"),
    workspace_max_entries: env_int.("POOL_WORKSPACE_MAX_ENTRIES", "100000"),
    archive_validation_timeout_ms: env_int.("POOL_ARCHIVE_VALIDATION_TIMEOUT_MS", "60000"),
    helper_extract_timeout_ms: env_int.("POOL_HELPER_EXTRACT_TIMEOUT_MS", "300000"),
    workspace_read_timeout_ms: env_int.("POOL_WORKSPACE_READ_TIMEOUT_MS", "300000"),
    workspace_max_concurrent_uploads_per_account:
      env_int.("POOL_WORKSPACE_MAX_CONCURRENT_UPLOADS_PER_ACCOUNT", "1"),
    transfer_chunk_bytes: env_int.("POOL_TRANSFER_CHUNK_BYTES", "1048576"),
    transfer_concurrency: env_int.("POOL_TRANSFER_CONCURRENCY", "2"),
    spool_max_bytes: env_int.("POOL_SPOOL_MAX_BYTES", "2147483648"),
    spool_account_max_bytes: env_int.("POOL_SPOOL_ACCOUNT_MAX_BYTES", "1073741824"),
    session_retention_ms: env_int.("POOL_SESSION_RETENTION_MS", "2592000000"),
    disconnect_grace_ms: env_int.("POOL_DISCONNECT_GRACE_MS", "60000"),
    max_session_lifetime_ms: env_int.("POOL_MAX_SESSION_LIFETIME_MS", "21600000"),
    acquire_timeout_max_ms: env_int.("POOL_ACQUIRE_TIMEOUT_MAX_MS", "600000"),
    exec_max_ms: env_int.("POOL_EXEC_MAX_MS", "3600000"),
    exec_buffer_bytes: env_int.("POOL_EXEC_BUFFER_BYTES", "1048576")

  if spool_dir = System.get_env("POOL_SPOOL_DIR"),
    do: config(:good_flows, GoodFlows.Pools, spool_dir: spool_dir)

  if helper_dir = System.get_env("POOL_HELPER_ARTIFACT_DIR"),
    do: config(:good_flows, GoodFlows.Pools, helper_artifact_dir: helper_dir)

  if secret = System.get_env("POOL_FINGERPRINT_SECRET"),
    do: config(:good_flows, GoodFlows.Pools, fingerprint_secret: secret)
end

# Spry run owner ids embed the node name; production nodes must be
# distributed with a stable name (rel/env.sh.eex sets RELEASE_DISTRIBUTION
# and RELEASE_NODE), so GoodFlows.Spry.Config.validate!/0 refuses to start
# PgFlow workers on :nonode@nohost.
if config_env() == :prod do
  config :good_flows, GoodFlows.Spry, require_named_node: true
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/good_flows start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :good_flows, GoodFlowsWeb.Endpoint, server: true
end

config :good_flows, GoodFlowsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  http_port = String.to_integer(System.get_env("PORT", "4000"))
  phx_host = System.get_env("PHX_HOST")
  remote_host? = is_binary(phx_host) and phx_host not in ["", "localhost"]
  url_host = if remote_host?, do: phx_host, else: "localhost"
  url_scheme = if remote_host?, do: System.get_env("PHX_SCHEME") || "https", else: "http"
  explicit_url_port = System.get_env("PHX_URL_PORT")

  url_port =
    cond do
      not remote_host? -> http_port
      explicit_url_port in [nil, ""] and url_scheme == "https" -> 443
      explicit_url_port in [nil, ""] -> http_port
      true -> String.to_integer(explicit_url_port)
    end

  issuer =
    cond do
      url_scheme == "https" and url_port == 443 -> "https://#{url_host}"
      url_scheme == "http" and url_port == 80 -> "http://#{url_host}"
      true -> "#{url_scheme}://#{url_host}:#{url_port}"
    end

  config :good_flows, :oauth, issuer: issuer

  # Reload browser tabs when matching files change.
  config :good_flows, GoodFlowsWeb.Endpoint,
    url: [host: url_host, port: url_port, scheme: url_scheme],
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/good_flows_web/router\.ex$"E,
        ~r"lib/good_flows_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Comma-separated browser origins allowed to call the JSON API. Unset = none.
  config :good_flows,
         :cors_origins,
         "CORS_ORIGINS"
         |> System.get_env("")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  pool_size = String.to_integer(System.get_env("POOL_SIZE") || "10")
  upload_cap = String.to_integer(System.get_env("TEST_REPORT_MAX_CONCURRENT_UPLOADS", "2"))

  if upload_cap * 2 > pool_size do
    raise """
    TEST_REPORT_MAX_CONCURRENT_UPLOADS (#{upload_cap}) must be at most half of
    POOL_SIZE (#{pool_size}): each test report upload can hold a Repo connection.
    """
  end

  config :good_flows, GoodFlows.Repo,
    # ssl: true,
    url: database_url,
    pool_size: pool_size,
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :good_flows, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :good_flows, GoodFlowsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # Pools: credential fingerprints are keyed with POOL_FINGERPRINT_SECRET,
  # falling back to SECRET_KEY_BASE (set POOL_FINGERPRINT_SECRET to the old
  # value before rotating SECRET_KEY_BASE, or every pool rebuilds its
  # members). A release without the packaged gf-transfer helper refuses to
  # boot while pools are enabled, instead of silently disabling them.
  config :good_flows, GoodFlows.Pools,
    fingerprint_secret: System.get_env("POOL_FINGERPRINT_SECRET") || secret_key_base,
    require_helper_manifest: true

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :good_flows, GoodFlowsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :good_flows, GoodFlowsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :good_flows, GoodFlows.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
