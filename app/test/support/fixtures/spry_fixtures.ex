defmodule GoodFlows.SpryFixtures do
  @moduledoc """
  Test helpers for Spry recipes, credentials, and runs.
  """

  alias GoodFlows.Projects
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.Spry
  alias GoodFlows.Spry.{Run, RunStep}
  alias PgFlow.Worker.Bootstrap

  def recipe_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "name" => "app-#{System.unique_integer([:positive])}",
      "setup" => ["echo setup"],
      "start" => ["echo start"],
      "stop" => ["echo stop"],
      "teardown" => ["echo teardown"]
    })
  end

  @doc """
  Inserts a project for the account with `attrs` (default slug
  `"project-<n>"`, unique per call). Always inserts: a duplicate slug or any
  other invalid attrs raise instead of reusing an existing project.
  """
  def project_fixture(account, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put_new_lazy("slug", fn -> "project-#{System.unique_integer([:positive])}" end)

    case Projects.create_project(account, attrs) do
      {:ok, project} ->
        project

      {:error, changeset} ->
        raise ArgumentError,
              "project_fixture could not insert #{inspect(attrs)}: " <>
                inspect(changeset.errors)
    end
  end

  def recipe_fixture(%Project{} = project, attrs \\ %{}) do
    account = Repo.get!(GoodFlows.Accounts.Account, project.account_id)
    {:ok, recipe} = Spry.create_recipe(account, project, recipe_attrs(attrs))
    recipe
  end

  def credential_fixture(account, token \\ "sprites_test_token_a1b2") do
    {:ok, credential} = Spry.put_credential(account, %{"token" => token})
    credential
  end

  @doc """
  Admits a real run through `Spry.request_run/5` (the single entry point),
  returning `{:ok, run}` or the error.
  """
  def start_run(account, project, recipe_id, params, opts \\ []) do
    case Spry.request_run(account, project, recipe_id, Map.delete(params, "dry_run"), opts) do
      {:ok, {:run, run}} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Dry-runs through `Spry.request_run/5`, returning `{:ok, result}` or the error."
  def dry_run(account, project, recipe_id, params) do
    case Spry.request_run(account, project, recipe_id, Map.put(params, "dry_run", true)) do
      {:ok, {:plan, result}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Inserts a run directly, bypassing admission (no PgFlow enqueue)."
  def run_fixture(account, recipe, attrs \\ %{}) do
    attrs = Map.new(attrs)
    phase = Map.get(attrs, :phase, "setup")
    sprite_name = Map.get(attrs, :sprite_name, recipe.name)
    commands = Map.get(attrs, :commands, Map.fetch!(recipe, String.to_existing_atom(phase)))

    defaults = %{
      account_id: account.id,
      recipe_id: recipe.id,
      phase: phase,
      sprite_name: sprite_name,
      inputs: %{},
      no_create: false,
      no_destroy: false,
      plan: %{"sprite_name" => sprite_name, "commands" => commands},
      status: "queued"
    }

    struct(Run, Map.merge(defaults, Map.drop(attrs, [:commands])))
    |> Repo.insert!()
  end

  def run_step_fixture(run, attrs) do
    struct(RunStep, Map.merge(%{run_id: run.id, status: "pending"}, Map.new(attrs)))
    |> Repo.insert!()
  end

  @doc "Compiles the Spry PgFlow job definitions into the current database (connection)."
  def compile_jobs! do
    for job <- [GoodFlows.Spry.RunJob, GoodFlows.Spry.ReapRunsJob] do
      {:ok, _} = Bootstrap.prepare(Repo, job.__pgflow_definition__())
    end

    :ok
  end

  @doc "Number of messages waiting in the run job's pgmq queue (0 when the queue does not exist)."
  def queued_job_messages do
    case Repo.query("SELECT count(*) FROM pgmq.q_spry_run") do
      {:ok, %{rows: [[count]]}} -> count
      {:error, _} -> 0
    end
  end

  def pgflow_run_count do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pgflow.runs WHERE flow_slug = 'spry_run'")

    count
  end
end
