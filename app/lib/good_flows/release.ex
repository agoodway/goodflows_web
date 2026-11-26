defmodule GoodFlows.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :good_flows

  alias GoodFlows.WorkflowRuns.Backfill

  @doc "Runs every pending migration for each repo (rel/overlays/bin/migrate)."
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls `repo` back down to migration `version`."
  @spec rollback(module(), integer()) :: :ok
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Runs `GoodFlows.WorkflowRuns.Backfill` for each repo
  (rel/overlays/bin/backfill_workflow_runs).

  Run it once after the code that fills `failed_jobs` and `parent_run_id`
  on ingest is serving: the old code keeps storing rows with empty columns
  while the migrations run, and the backfill migration's batches skip rows
  stored behind its cursor. It is idempotent and runs in batches outside a
  migration, so it is safe to run while uploads continue.
  """
  @spec backfill_workflow_runs() :: :ok
  def backfill_workflow_runs do
    load_app()

    for repo <- repos() do
      {:ok, :ok, _} = Ecto.Migrator.with_repo(repo, &Backfill.run/1)
    end

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
