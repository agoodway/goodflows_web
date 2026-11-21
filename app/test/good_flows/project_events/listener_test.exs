defmodule GoodFlows.ProjectEvents.ListenerTest do
  use ExUnit.Case, async: true

  alias GoodFlows.ProjectEvents.Listener

  test "keeps the Repo's connection keys, so the listener reaches the same database" do
    config = [
      hostname: "db.internal",
      port: 6543,
      username: "app",
      password: "secret",
      database: "good_flows",
      ssl: true,
      socket_options: [:inet6],
      connect_timeout: 5_000,
      pool_size: 10,
      telemetry_prefix: [:good_flows, :repo]
    ]

    assert Enum.sort(Listener.connection_options(config)) ==
             Enum.sort(
               hostname: "db.internal",
               port: 6543,
               username: "app",
               password: "secret",
               database: "good_flows",
               ssl: true,
               socket_options: [:inet6],
               connect_timeout: 5_000,
               auto_reconnect: true
             )
  end
end
