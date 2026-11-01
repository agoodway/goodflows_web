defmodule GoodFlowsWeb.Api.V1.RunJSON do
  @moduledoc """
  Renders runs, run steps, and dry-run plans for the JSON API.

  Worker bookkeeping (`owner_id`, `pgflow_run_id`, `action_started_at`,
  `reaper_checked_at`) and the stored `plan` are never rendered. Step
  `command` and `output` are rendered only when `full_steps?` is true
  (private keys), because step lines and their output can carry secrets.
  """

  alias GoodFlows.Spry.{Run, RunStep}

  @run_fields [
    :id,
    :recipe_id,
    :status,
    :phase,
    :sprite_name,
    :inputs,
    :no_create,
    :no_destroy,
    :error,
    :started_by_api_key_id,
    :started_at,
    :finished_at,
    :inserted_at,
    :updated_at
  ]

  @step_fields [
    :index,
    :kind,
    :status,
    :exit_code,
    :reason,
    :output_truncated,
    :started_at,
    :finished_at
  ]

  @private_step_fields [:command, :output]

  @doc "Renders one page of a recipe's runs without steps."
  def index(%{runs: runs} = assigns) do
    %{data: Enum.map(runs, &run/1), next_cursor: Map.get(assigns, :next_cursor)}
  end

  @doc "Renders one run, with steps when they are loaded."
  def show(%{run: %Run{steps: steps} = run} = assigns) when is_list(steps) do
    full? = Map.get(assigns, :full_steps?, false)
    %{data: Map.put(run(run), :steps, Enum.map(steps, &step(&1, full?)))}
  end

  def show(%{run: run}), do: %{data: run(run)}

  @doc "Renders a dry-run plan."
  def plan(%{plan: plan, sprite_exists: exists?, steps: steps}) do
    %{
      data: %{
        phase: plan.phase,
        sprite_name: plan.sprite_name,
        sprite_exists: exists?,
        no_create: plan.no_create,
        no_destroy: plan.no_destroy,
        inputs: plan.inputs,
        steps:
          steps
          |> Enum.with_index()
          |> Enum.map(fn {action, index} -> Map.put(action, :index, index) end)
      }
    }
  end

  defp run(%Run{} = run), do: Map.take(run, @run_fields)

  defp step(%RunStep{} = step, true), do: Map.take(step, @step_fields ++ @private_step_fields)
  defp step(%RunStep{} = step, false), do: Map.take(step, @step_fields)
end
