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

# Sentry error tracking
if sentry_dsn = System.get_env("SENTRY_DSN") do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: config_env()
end

# Single source for non-test boots (dev + prod + releases). Omitted in test
# so GoodFlows.Application does not start PgFlow workers.
if config_env() != :test do
  config :good_flows, PgFlow,
    repo: GoodFlows.Repo,
    jobs: [],
    flows: [],
    max_concurrency: 10,
    signal_strategy: :notify
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

  config :good_flows, GoodFlows.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
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
