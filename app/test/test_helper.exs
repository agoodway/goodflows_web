Mimic.copy(Sprites)
Mimic.copy(Sprites.Checkpoint)
Mimic.copy(Sprites.Filesystem)
Mimic.copy(GoodFlows.Spry.Sprites)
Mimic.copy(PgFlow)
Mimic.copy(GoodFlows.Spry)
Mimic.copy(GoodFlows.Spry.Executions)
Mimic.copy(GoodFlows.Spry.Run)
Mimic.copy(GoodFlows.TestReports.Store)
Mimic.copy(GoodFlows.Pools)
Mimic.copy(GoodFlows.Pools.Execs)
Mimic.copy(GoodFlows.Pools.Sessions)
Mimic.copy(PgFlow.Runs)
Mimic.copy(GoodFlows.Pools.OwnerRPC)
Mimic.copy(GoodFlows.Pools.Transfers)
Mimic.copy(GoodFlows.Pools.Reconciler)

# :slow tests run in `mix precommit` (`mix test --include slow`).
# :helper_binary tests run the real gf-transfer helper locally
# (GoodFlows.FakeSprite). `mix check` / `mix precommit` build it first
# (`cargo build --manifest-path ../sprite-transfer/Cargo.toml`). Without it
# those tests are skipped with a warning locally, and the run fails when the
# CI environment variable is set, so CI can never skip them silently.
exclude =
  if GoodFlows.FakeSprite.helper_binary() do
    [:slow]
  else
    message =
      "the gf-transfer helper is not built: the :helper_binary tests (workspace and " <>
        "report transfers, hydration, end to end) are SKIPPED. Build it with " <>
        "`cargo build --manifest-path ../sprite-transfer/Cargo.toml`."

    if System.get_env("CI") in ["true", "1"], do: raise(message)
    IO.puts(:stderr, "\nwarning: " <> message <> "\n")
    [:slow, :helper_binary]
  end

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(GoodFlows.Repo, :manual)
