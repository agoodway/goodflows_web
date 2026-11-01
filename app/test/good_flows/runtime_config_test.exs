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
end
