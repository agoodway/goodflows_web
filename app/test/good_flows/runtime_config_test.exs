defmodule GoodFlows.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "PHX_HOST builds https magic-link URLs without localhost" do
    original = %{
      "PHX_HOST" => System.get_env("PHX_HOST"),
      "PHX_SCHEME" => System.get_env("PHX_SCHEME"),
      "PHX_URL_PORT" => System.get_env("PHX_URL_PORT"),
      "PORT" => System.get_env("PORT")
    }

    try do
      System.put_env("PHX_HOST", "demo-bn4gb.sprites.app")
      System.put_env("PHX_SCHEME", "https")
      System.put_env("PHX_URL_PORT", "443")
      System.delete_env("PORT")

      {config, _imports} =
        Config.Reader.read_imports!("config/runtime.exs", env: :dev, target: :host)

      url = get_in(config, [:good_flows, GoodFlowsWeb.Endpoint, :url])
      assert url[:host] == "demo-bn4gb.sprites.app"
      assert url[:scheme] == "https"
      assert url[:port] == 443
      assert get_in(config, [:good_flows, :oauth, :issuer]) == "https://demo-bn4gb.sprites.app"
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  test "pool settings come from the environment and the member jobs are registered" do
    names = ~w(POOLS_ENABLED POOL_SPOOL_DIR POOL_EXEC_MAX_MS POOL_PROVISION_MAX_CONCURRENCY)
    original = Map.new(names, &{&1, System.get_env(&1)})

    try do
      System.put_env("POOLS_ENABLED", "false")
      System.put_env("POOL_SPOOL_DIR", "/var/spool/goodflows")
      System.put_env("POOL_EXEC_MAX_MS", "120000")
      System.put_env("POOL_PROVISION_MAX_CONCURRENCY", "3")

      {config, _imports} =
        Config.Reader.read_imports!("config/runtime.exs", env: :dev, target: :host)

      pools = get_in(config, [:good_flows, GoodFlows.Pools])
      assert pools[:enabled] == false
      assert pools[:spool_dir] == "/var/spool/goodflows"
      assert pools[:exec_max_ms] == 120_000

      pgflow = get_in(config, [:good_flows, PgFlow])

      for job <- [
            GoodFlows.Pools.ProvisionMemberJob,
            GoodFlows.Pools.ResetMemberJob,
            GoodFlows.Pools.DestroyMemberJob
          ] do
        assert job in pgflow[:jobs]
        assert pgflow[:worker_options][job][:max_concurrency]
      end

      assert pgflow[:worker_options][GoodFlows.Pools.ProvisionMemberJob][:max_concurrency] == 3
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  test "production requires the helper manifest and keys fingerprints off the web secret" do
    names =
      ~w(DATABASE_URL SECRET_KEY_BASE CLOAK_KEY POOL_FINGERPRINT_SECRET POOL_SPOOL_ACCOUNT_MAX_BYTES
         POOL_SESSION_RETENTION_MS)

    original = Map.new(names, &{&1, System.get_env(&1)})

    read = fn ->
      {config, _imports} =
        Config.Reader.read_imports!("config/runtime.exs", env: :prod, target: :host)

      get_in(config, [:good_flows, GoodFlows.Pools])
    end

    try do
      System.put_env("DATABASE_URL", "ecto://u:p@localhost/db")
      System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
      System.put_env("CLOAK_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
      System.delete_env("POOL_FINGERPRINT_SECRET")
      System.put_env("POOL_SPOOL_ACCOUNT_MAX_BYTES", "536870912")
      System.put_env("POOL_SESSION_RETENTION_MS", "86400000")

      pools = read.()
      assert pools[:require_helper_manifest] == true
      assert pools[:fingerprint_secret] == String.duplicate("s", 64)
      assert pools[:spool_account_max_bytes] == 536_870_912
      assert pools[:session_retention_ms] == 86_400_000

      System.put_env("POOL_FINGERPRINT_SECRET", "pinned")
      assert read.()[:fingerprint_secret] == "pinned"
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
