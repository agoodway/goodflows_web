defmodule GoodFlows.Spry.ConfigTest do
  use ExUnit.Case, async: false

  alias GoodFlows.Spry.Config

  setup do
    original = Application.get_env(:good_flows, GoodFlows.Spry)
    on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Spry, original) end)
    %{original: original}
  end

  test "accepts the test configuration" do
    assert Config.validate!() == :ok
  end

  test "defaults cover the 6 hour budget plus 5 minutes" do
    Application.put_env(:good_flows, GoodFlows.Spry, run_timeout_ms: 6 * 60 * 60_000)
    assert Config.validate!() == :ok
    assert Config.job_timeout_seconds() == 21_900
  end

  test "rejects a run budget the job timeout cannot cover" do
    Application.put_env(:good_flows, GoodFlows.Spry, run_timeout_ms: 6 * 60 * 60_000 + 1)
    assert_raise ArgumentError, ~r/must cover run_timeout_ms/, fn -> Config.validate!() end
  end

  test "rejects non-positive settings", %{original: original} do
    Application.put_env(:good_flows, GoodFlows.Spry, Keyword.put(original, :step_timeout_ms, 0))
    assert_raise ArgumentError, ~r/step_timeout_ms/, fn -> Config.validate!() end
  end

  test "the queued reap age defaults to the run budget plus overhead and is configurable", %{
    original: original
  } do
    assert Config.queued_reap_after_ms() ==
             Config.run_timeout_ms() + Config.finalization_overhead_ms()

    Application.put_env(
      :good_flows,
      GoodFlows.Spry,
      Keyword.put(original, :queued_reap_after_ms, 42)
    )

    assert Config.queued_reap_after_ms() == 42

    Application.put_env(
      :good_flows,
      GoodFlows.Spry,
      Keyword.put(original, :queued_reap_after_ms, 0)
    )

    assert_raise ArgumentError, ~r/queued_reap_after_ms/, fn -> Config.validate!() end
  end

  describe "named node requirement" do
    test "refuses an undistributed node with PgFlow configured when required", %{
      original: original
    } do
      Application.put_env(
        :good_flows,
        GoodFlows.Spry,
        Keyword.put(original, :require_named_node, true)
      )

      assert_raise ArgumentError, ~r/RELEASE_NODE/, fn ->
        Config.validate!(Config.job_timeout_seconds(), node: :nonode@nohost, pgflow?: true)
      end

      assert Config.validate!(Config.job_timeout_seconds(), node: :app@host, pgflow?: true) ==
               :ok

      assert Config.validate!(Config.job_timeout_seconds(), node: :nonode@nohost, pgflow?: false) ==
               :ok
    end

    test "allows an undistributed node when not required (dev and test)" do
      assert Config.validate!(Config.job_timeout_seconds(), node: :nonode@nohost, pgflow?: true) ==
               :ok
    end
  end
end
