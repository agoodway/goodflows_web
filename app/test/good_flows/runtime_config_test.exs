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

  describe "cache limits" do
    defp read_runtime(env) do
      original = Map.new(Map.keys(env), &{&1, System.get_env(&1)})

      try do
        Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
        {config, _imports} = Config.Reader.read_imports!("config/runtime.exs", env: :dev)
        config
      after
        Enum.each(original, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end
    end

    test "defaults and the CACHE_S3_* settings are read" do
      config =
        read_runtime(%{
          "CACHE_S3_BUCKET" => "caches",
          "CACHE_S3_ENDPOINT" => "https://acct.r2.cloudflarestorage.com",
          "CACHE_S3_REGION" => "auto",
          "CACHE_S3_ACCESS_KEY_ID" => "id",
          "CACHE_S3_SECRET_ACCESS_KEY" => "secret"
        })

      store = get_in(config, [:good_flows, GoodFlows.Caches.ObjectStore])
      assert store[:bucket] == "caches"
      assert store[:endpoint] == "https://acct.r2.cloudflarestorage.com"
      assert get_in(config, [:good_flows, :cache_max_entry_bytes]) == 5_000_000_000
      assert get_in(config, [:good_flows, :cache_project_quota_bytes]) == 53_687_091_200
      assert get_in(config, [:good_flows, :cache_reservation_ttl_seconds]) == 7_200
      assert get_in(config, [:good_flows, :cache_max_keys_per_project]) == 1_000
    end

    test "CACHE_MAX_KEYS_PER_PROJECT is read" do
      config = read_runtime(%{"CACHE_MAX_KEYS_PER_PROJECT" => "25"})
      assert get_in(config, [:good_flows, :cache_max_keys_per_project]) == 25
    end

    test "the server refuses to boot with a bucket but blank credentials" do
      for {id, secret} <- [{"", "secret"}, {"id", ""}, {"", ""}] do
        assert_raise RuntimeError, ~r/CACHE_S3_ACCESS_KEY_ID/, fn ->
          read_runtime(%{
            "CACHE_S3_BUCKET" => "caches",
            "CACHE_S3_ACCESS_KEY_ID" => id,
            "CACHE_S3_SECRET_ACCESS_KEY" => secret
          })
        end
      end
    end

    test "the server refuses to boot with an upload URL TTL above the reservation TTL" do
      assert_raise RuntimeError, ~r/CACHE_UPLOAD_URL_TTL_SECONDS/, fn ->
        read_runtime(%{
          "CACHE_UPLOAD_URL_TTL_SECONDS" => "7201",
          "CACHE_RESERVATION_TTL_SECONDS" => "7200"
        })
      end

      config =
        read_runtime(%{
          "CACHE_UPLOAD_URL_TTL_SECONDS" => "7200",
          "CACHE_RESERVATION_TTL_SECONDS" => "7200"
        })

      assert get_in(config, [:good_flows, :cache_upload_url_ttl_seconds]) == 7_200
    end

    test "the server refuses to boot with a reservation TTL above a week" do
      assert_raise RuntimeError, ~r/CACHE_RESERVATION_TTL_SECONDS \(604801\)/, fn ->
        read_runtime(%{"CACHE_RESERVATION_TTL_SECONDS" => "604801"})
      end

      config = read_runtime(%{"CACHE_RESERVATION_TTL_SECONDS" => "604800"})
      assert get_in(config, [:good_flows, :cache_reservation_ttl_seconds]) == 604_800
    end

    test "an entry cap at R2's single-request limit is accepted" do
      config = read_runtime(%{"CACHE_MAX_ENTRY_BYTES" => "5363466240"})
      assert get_in(config, [:good_flows, :cache_max_entry_bytes]) == 5_363_466_240
    end

    test "the server refuses to boot with an entry cap above R2's limit" do
      assert_raise RuntimeError, ~r/CACHE_MAX_ENTRY_BYTES/, fn ->
        read_runtime(%{"CACHE_MAX_ENTRY_BYTES" => "5363466241"})
      end
    end

    test "the server refuses to boot with an entry cap above the project quota" do
      assert_raise RuntimeError, ~r/CACHE_PROJECT_QUOTA_BYTES/, fn ->
        read_runtime(%{
          "CACHE_MAX_ENTRY_BYTES" => "2000",
          "CACHE_PROJECT_QUOTA_BYTES" => "1000"
        })
      end
    end
  end
end
