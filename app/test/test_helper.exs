Mimic.copy(Sprites)
Mimic.copy(GoodFlows.Spry.Sprites)
Mimic.copy(PgFlow)
Mimic.copy(GoodFlows.Spry)
Mimic.copy(GoodFlows.Spry.Executions)
Mimic.copy(GoodFlows.Spry.Run)
Mimic.copy(GoodFlows.TestReports.Store)
Mimic.copy(GoodFlows.WorkflowRuns.Store)
Mimic.copy(PgFlow.Runs)

# :slow tests run in `mix precommit` (`mix test --include slow`).
ExUnit.start(exclude: [:slow])
Ecto.Adapters.SQL.Sandbox.mode(GoodFlows.Repo, :manual)
