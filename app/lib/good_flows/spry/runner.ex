defmodule GoodFlows.Spry.Runner do
  @moduledoc """
  Executes an admitted run on behalf of `GoodFlows.Spry.RunJob`.

    1. Claims the run with a conditional `queued → running` update that
       records a fresh owner id; zero rows means a duplicate or late delivery
       and nothing happens.
    2. Registers the owner in `GoodFlows.Spry.Executions` and fetches the
       account's current credential once; the one client is used for every
       operation of the run and is never persisted.
    3. Everything after the claim, including the credential fetch, runs
       under `rescue`/`catch` (raises, throws, and exits), so any catchable
       failure finalizes the run as `failed`.
    4. Looks up the sprite, materializes `run_steps` from the plan snapshot,
       and runs them in order, failing fast and skipping the remainder.

  Every action is bounded by the smaller of the step timeout and the
  remaining total-run budget. Every write is conditional on the run still
  being `running` under this owner, so a reaped run is never overwritten and
  a stale worker never issues another VM action.
  """
  import Ecto.Query

  alias GoodFlows.Repo
  alias GoodFlows.Spry
  alias GoodFlows.Spry.{Config, Executions, Plan, Run, RunStep, Sprites}

  @doc """
  Claims and executes the run. Returns a JSON-safe summary for PgFlow:
  `"skipped"` when the run was not queued, `"lost"` when ownership ended
  mid-run, otherwise the final status.
  """
  @spec execute(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: %{String.t() => String.t()}
  def execute(run_id, pgflow_run_id \\ nil) do
    owner_id = Executions.new_owner_id()
    :ok = Executions.register(owner_id)

    try do
      result =
        case claim(run_id, owner_id, pgflow_run_id) do
          {:ok, run} -> run_claimed(run, owner_id)
          :not_queued -> "skipped"
        end

      %{"run_id" => run_id, "result" => result}
    after
      Executions.unregister(owner_id)
    end
  end

  defp claim(run_id, owner_id, pgflow_run_id) do
    now = DateTime.utc_now()

    set =
      [
        status: "running",
        owner_id: owner_id,
        started_at: now,
        action_started_at: now,
        updated_at: now
      ] ++
        if(pgflow_run_id, do: [pgflow_run_id: pgflow_run_id], else: [])

    case Run
         |> where([r], r.id == ^run_id and r.status == "queued")
         |> Repo.update_all(set: set) do
      {1, _} -> {:ok, Repo.get!(Run, run_id)}
      {0, _} -> :not_queued
    end
  end

  defp run_claimed(run, owner_id) do
    state = %{
      run: run,
      owner_id: owner_id,
      deadline: System.monotonic_time(:millisecond) + Config.run_timeout_ms(),
      token: nil
    }

    # Credential fetch (including decryption) is protected too, so a
    # failure there finalizes the run instead of leaving it `running`.
    protected(state, fn -> with_credential(state) end)
  end

  defp with_credential(state) do
    case Spry.fetch_token(state.run.account_id) do
      {:ok, token} ->
        state = %{state | token: token}
        protected(state, fn -> run_with_client(state) end)

      {:error, :no_credential} ->
        finish(state, "failed", "Sprites credential is not configured for this account")
    end
  end

  defp run_with_client(state) do
    run_plan(state, Sprites.client(state.token), Plan.from_run(state.run))
  end

  # Turns any catchable failure (raise, throw, or exit, e.g. a GenServer
  # call timing out) into a failed run with a token-scrubbed message.
  defp protected(state, fun) do
    fun.()
  rescue
    error -> fail_internal(state, Exception.message(error))
  catch
    :exit, reason -> fail_internal(state, "process exited: #{inspect(reason)}")
    :throw, value -> fail_internal(state, "uncaught throw: #{inspect(value)}")
  end

  defp fail_internal(state, detail) do
    detail = detail |> scrub(state.token) |> String.slice(0, 1_000)
    finish(state, "failed", "internal error: #{detail}")
  end

  defp run_plan(state, client, plan) do
    with {:ok, exists?} <- lookup(state, client, plan.sprite_name),
         {:ok, actions} <- vm_actions(plan, exists?),
         {:ok, steps} <- insert_steps(state, actions) do
      execute_steps(state, client, plan.sprite_name, steps)
    else
      {:fail, error} -> finish(state, "failed", error)
      :lost -> "lost"
    end
  end

  defp lookup(state, client, name) do
    with :ok <- touch(state),
         {:ok, timeout, budget_limited?} <- action_timeout(state) do
      case Sprites.exists?(client, name, timeout: timeout) do
        {:ok, exists?} ->
          {:ok, exists?}

        {:error, :timeout} when budget_limited? ->
          {:fail, "run_timeout"}

        {:error, :timeout} ->
          {:fail, "timed out checking whether sprite #{name} exists"}

        {:error, error} ->
          {:fail,
           "could not check whether sprite #{name} exists: #{Sprites.error_message(error)}"}
      end
    end
  end

  defp vm_actions(plan, exists?) do
    case Plan.with_vm_state(plan, exists?) do
      {:ok, actions} -> {:ok, actions}
      {:error, message} -> {:fail, message}
    end
  end

  defp insert_steps(state, actions) do
    owned_transaction(state, fn ->
      now = DateTime.utc_now()

      entries =
        actions
        |> Enum.with_index()
        |> Enum.map(fn {action, index} ->
          %{
            id: Ecto.UUID.generate(),
            run_id: state.run.id,
            index: index,
            kind: action.kind,
            command: action.command,
            status: "pending",
            output_truncated: false,
            inserted_at: now,
            updated_at: now
          }
        end)

      {_count, steps} = Repo.insert_all(RunStep, entries, returning: true)
      Enum.sort_by(steps, & &1.index)
    end)
  end

  defp execute_steps(state, client, name, steps) do
    outcome =
      Enum.reduce_while(steps, :ok, fn step, :ok ->
        case run_step(state, client, name, step) do
          :ok -> {:cont, :ok}
          other -> {:halt, other}
        end
      end)

    case outcome do
      :ok -> finish(state, "succeeded", nil)
      {:fail, error} -> finish(state, "failed", error)
      :lost -> "lost"
    end
  end

  # The budget is checked again after `start_step/2`, whose transaction may
  # wait on a connection or row lock, so no action starts past the deadline.
  # A step left running is failed with `run_timeout` by `finalize/5`.
  defp run_step(state, client, name, step) do
    with {:ok, _, _} <- action_timeout(state),
         {:ok, _} <- start_step(state, step),
         {:ok, timeout, budget_limited?} <- action_timeout(state) do
      result = perform(step.kind, client, name, step.command, timeout)
      record(state, step, result, budget_limited?)
    end
  end

  defp perform("create", client, name, _command, timeout),
    do: Sprites.create(client, name, timeout: timeout)

  defp perform("destroy", client, name, _command, timeout),
    do: Sprites.destroy(client, name, timeout: timeout)

  defp perform("exec", client, name, command, timeout),
    do: Sprites.exec(client, name, command, timeout: timeout)

  defp record(state, step, result, budget_limited?) do
    {attrs, outcome} = step_outcome(step, result, budget_limited?)
    attrs = Keyword.put(attrs, :finished_at, DateTime.utc_now())

    case update_step(state, step, attrs) do
      {:ok, _} -> outcome
      :lost -> :lost
    end
  end

  defp step_outcome(_step, :ok, _budget_limited?), do: {[status: "succeeded"], :ok}

  defp step_outcome(_step, {:ok, %{exit_code: 0} = result}, _budget_limited?) do
    {[
       status: "succeeded",
       exit_code: 0,
       output: result.output,
       output_truncated: result.output_truncated
     ], :ok}
  end

  defp step_outcome(step, {:ok, %{exit_code: code} = result}, _budget_limited?) do
    {[
       status: "failed",
       exit_code: code,
       reason: "exit_code",
       output: result.output,
       output_truncated: result.output_truncated
     ], {:fail, "step #{step.index} (#{step.kind}) exited with code #{code}"}}
  end

  defp step_outcome(_step, {:error, :timeout}, true) do
    {[status: "failed", reason: "run_timeout"], {:fail, "run_timeout"}}
  end

  defp step_outcome(step, {:error, :timeout}, false) do
    {[status: "failed", reason: "timeout"],
     {:fail, "step #{step.index} (#{step.kind}) timed out"}}
  end

  defp step_outcome(step, {:error, error}, _budget_limited?) do
    message = Sprites.error_message(error)

    {[status: "failed", reason: message],
     {:fail, "step #{step.index} (#{step.kind}) failed: #{message}"}}
  end

  # The smaller of the step timeout and the remaining run budget. An
  # exhausted budget fails the run before another action is issued.
  defp action_timeout(state) do
    remaining = state.deadline - System.monotonic_time(:millisecond)
    step_timeout = Config.step_timeout_ms()

    cond do
      remaining <= 0 -> {:fail, "run_timeout"}
      remaining < step_timeout -> {:ok, remaining, true}
      true -> {:ok, step_timeout, false}
    end
  end

  ## Ownership-conditional writes

  defp touch(state) do
    case owned_transaction(state, fn -> :ok end) do
      {:ok, :ok} -> :ok
      :lost -> :lost
    end
  end

  defp start_step(state, step) do
    owned_transaction(state, fn ->
      RunStep
      |> where([s], s.id == ^step.id and s.status == "pending")
      |> Repo.update_all(
        set: [status: "running", started_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
      )
    end)
  end

  defp update_step(state, step, attrs) do
    owned_transaction(state, fn ->
      RunStep
      |> where([s], s.id == ^step.id)
      |> Repo.update_all(set: Keyword.put(attrs, :updated_at, DateTime.utc_now()))
    end)
  end

  # Locks the run row and runs `fun` only while the run is `running` under
  # this owner, refreshing `action_started_at` for the reaper.
  defp owned_transaction(state, fun) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      case Run
           |> where(
             [r],
             r.id == ^state.run.id and r.status == "running" and r.owner_id == ^state.owner_id
           )
           |> Repo.update_all(set: [action_started_at: now, updated_at: now]) do
        {1, _} -> fun.()
        {0, _} -> Repo.rollback(:lost)
      end
    end)
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, :lost} -> :lost
    end
  end

  defp finish(state, status, error) do
    case finalize(state.run.id, state.owner_id, status, error, if(status == "failed", do: error)) do
      :ok -> status
      :noop -> "lost"
    end
  end

  @doc """
  Atomically moves a `running` run owned by `owner_id` to `status`, failing
  its running step (with `step_reason`) and skipping pending steps. Returns
  `:noop` when the run is no longer running under that owner.
  """
  @spec finalize(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | :noop
  def finalize(run_id, owner_id, status, error, step_reason) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      case Run
           |> where([r], r.id == ^run_id and r.status == "running" and r.owner_id == ^owner_id)
           |> Repo.update_all(
             set: [status: status, error: error, finished_at: now, updated_at: now]
           ) do
        {1, _} -> close_steps(run_id, step_reason, now)
        {0, _} -> Repo.rollback(:noop)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, :noop} -> :noop
    end
  end

  defp close_steps(run_id, step_reason, now) do
    RunStep
    |> where([s], s.run_id == ^run_id and s.status == "running")
    |> Repo.update_all(
      set: [
        status: "failed",
        reason: step_reason || "interrupted",
        finished_at: now,
        updated_at: now
      ]
    )

    RunStep
    |> where([s], s.run_id == ^run_id and s.status == "pending")
    |> Repo.update_all(set: [status: "skipped", updated_at: now])
  end

  defp scrub(message, token) when is_binary(token) and token != "",
    do: String.replace(message, token, "[REDACTED]")

  defp scrub(message, _token), do: message
end
