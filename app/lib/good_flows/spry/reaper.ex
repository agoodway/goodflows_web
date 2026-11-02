defmodule GoodFlows.Spry.Reaper do
  @moduledoc """
  Recovers runs whose worker was lost, so they stop blocking new runs, and
  enforces step output retention.

  Staleness only nominates candidates; it never proves an owner is gone.

    * A `queued` run older than `Config.queued_reap_after_ms/0` (default the
      run budget plus 5 minutes) is checked against its PgFlow job. While the
      job is still pending (for example waiting for worker capacity) the run
      is left alone. Only when the job is missing or terminal is the run
      failed, by a conditional `queued → failed` update that races safely
      with the worker claim.
    * A `running` run whose current action exceeded the step timeout plus
      5 minutes, or whose total budget plus 5 minutes has elapsed, is
      investigated: its recorded owner is looked up on the owner's node and
      boot via `GoodFlows.Spry.Executions`. A live owner is killed together
      with its local action tasks and command processes, and must be
      confirmed dead. If the owner cannot be reached (unknown node, an
      unreachable node, or another instance's boot under the same node name)
      the run keeps its active guard until the bounded fallback below.
    * Bounded fallback: once `started_at` plus the PgFlow hard job timeout
      plus 5 minutes (`Config.owner_deadline_ms/0`) has passed, the owner's
      PgFlow task has been killed by its own node and the worker's own run
      budget has expired, so an unknown or unreachable owner is treated as
      terminated. A worker that somehow survived is still fenced: every
      worker write is conditional on its owner id and `running` status.
      A reachable owner whose kill cannot be confirmed is never released
      this way.
    * Finalization is conditional on the run still being `running` under
      the same owner, so it never overwrites a completed run.
    * Candidates are investigated concurrently (at most 10 at a time, each
      bounded to 20 seconds), and a sweep takes at most 50 running
      candidates (and checks at most 200 queued ones). Runs that were
      investigated and retained are stamped with `reaper_checked_at` and
      ordered after never-checked runs (`NULLS FIRST`, then least recently
      checked), so a backlog of retained runs cannot starve newer
      candidates. The worst case (5 rounds of 20 seconds) stays well inside
      the 300-second `ReapRunsJob` timeout.
    * Output retention: `output` of steps finished longer ago than
      `Config.output_retention_ms/0` is cleared (at most 5,000 steps per
      sweep).

  Owner ids embed the owner's node name and boot id; set a stable
  `RELEASE_NODE` (see `rel/env.sh.eex`). An operator who has established
  that an owner is gone can release its run before the fallback with
  `force_abandon/1` (or `mix spry.force_abandon RUN_ID`, or
  `bin/good_flows rpc 'GoodFlows.Spry.force_abandon("RUN_ID")'` in a
  release).
  """
  import Ecto.Query

  require Logger

  alias GoodFlows.Repo
  alias GoodFlows.Spry.{Config, Executions, Run, Runner, RunStep}

  @rpc_timeout_ms 15_000
  @max_concurrency 10
  @max_candidates 50
  @max_queued_candidates 200
  @output_purge_batch 5_000
  # Covers the RPC timeout (which includes remote kill confirmation) plus
  # finalization. ceil(50 / 10) * 20s = 100s, well under the job timeout.
  @investigation_timeout_ms 20_000

  @type summary :: %{
          queued_failed: non_neg_integer(),
          running_failed: non_neg_integer(),
          retained: non_neg_integer(),
          outputs_purged: non_neg_integer()
        }

  @doc """
  Runs one sweep.

  Options (tests): `:now` overrides the current time, and
  `:investigation_timeout_ms` the per-candidate bound (default 20 seconds).
  """
  @spec reap(keyword()) :: summary()
  def reap(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    timeout = Keyword.get(opts, :investigation_timeout_ms, @investigation_timeout_ms)
    queued_failed = fail_stale_queued(now)

    candidates = running_candidates(now)

    {failed, retained} =
      candidates
      |> Task.async_stream(&investigate(&1, now),
        max_concurrency: @max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(candidates)
      |> Enum.map(fn
        {{:ok, outcome}, _run} ->
          outcome

        {{:exit, reason}, run} ->
          Logger.warning(
            "Spry run #{run.id}: owner investigation did not finish (#{inspect(reason)}); " <>
              "keeping its active guard"
          )

          mark_checked(run, now)
          :retained
      end)
      |> Enum.split_with(&(&1 == :failed))

    %{
      queued_failed: queued_failed,
      running_failed: length(failed),
      retained: length(retained),
      outputs_purged: purge_output(now)
    }
  end

  ## Queued runs

  defp fail_stale_queued(now) do
    cutoff = DateTime.add(now, -Config.queued_reap_after_ms(), :millisecond)

    Run
    |> where([r], r.status == "queued" and r.inserted_at < ^cutoff)
    |> order_by([r], asc_nulls_first: r.reaper_checked_at, asc: r.inserted_at, asc: r.id)
    |> limit(@max_queued_candidates)
    |> select([r], struct(r, [:id, :pgflow_run_id]))
    |> Repo.all()
    |> Enum.count(fn run ->
      if job_gone?(run) do
        fail_queued(run, now)
      else
        mark_checked(run, now, "queued")
        false
      end
    end)
  end

  # A queued run's job is gone when PgFlow has no record of it or has
  # finished it (a terminal job can never claim the run). An unreadable job
  # state leaves the run queued for the next sweep.
  defp job_gone?(%Run{pgflow_run_id: nil}), do: true

  defp job_gone?(%Run{pgflow_run_id: pgflow_run_id}) do
    case PgFlow.get_run(pgflow_run_id) do
      {:ok, %{status: status}} -> status in ["completed", "failed"]
      {:error, reason} when reason in [:not_found, :invalid_id] -> true
      _other -> false
    end
  rescue
    _ -> false
  end

  defp fail_queued(run, now) do
    {count, _} =
      Run
      |> where([r], r.id == ^run.id and r.status == "queued")
      |> Repo.update_all(
        set: [
          status: "failed",
          error: "abandoned: the run was never claimed by a worker",
          finished_at: now,
          updated_at: now
        ]
      )

    count == 1
  end

  ## Running runs

  defp running_candidates(now) do
    grace = Config.finalization_overhead_ms()
    run_cutoff = DateTime.add(now, -(Config.run_timeout_ms() + grace), :millisecond)
    action_cutoff = DateTime.add(now, -(Config.step_timeout_ms() + grace), :millisecond)

    Run
    |> where([r], r.status == "running")
    |> where([r], r.started_at < ^run_cutoff or r.action_started_at < ^action_cutoff)
    |> order_by([r],
      asc_nulls_first: r.reaper_checked_at,
      asc: r.action_started_at,
      asc: r.id
    )
    |> limit(@max_candidates)
    |> Repo.all()
  end

  defp investigate(%Run{} = run, now) do
    case stop_owner(run.owner_id) do
      :terminated ->
        finalize_abandoned(run, now)

      {:retain, reason} ->
        if unreachable?(reason) and past_owner_deadline?(run, now) do
          Logger.warning(
            "Spry run #{run.id}: owner #{inspect(run.owner_id)} could not be reached " <>
              "(#{inspect(reason)}) and the run is past its owner deadline; treating the owner " <>
              "as terminated"
          )

          finalize_abandoned(run, now)
        else
          Logger.warning(
            "Spry run #{run.id} is stale but its owner #{inspect(run.owner_id)} could not be " <>
              "confirmed terminated (#{inspect(reason)}); keeping its active guard"
          )

          mark_checked(run, now)
          :retained
        end
    end
  end

  # Reasons that mean the owner could not be asked at all. A reachable
  # owner whose kill was not confirmed is deliberately excluded.
  defp unreachable?(:unknown_owner_node), do: true
  defp unreachable?(:foreign_boot), do: true
  defp unreachable?({:unreachable, _detail}), do: true
  defp unreachable?(_reason), do: false

  defp past_owner_deadline?(%Run{} = run, now) do
    claimed_at = run.started_at || run.inserted_at

    DateTime.compare(DateTime.add(claimed_at, Config.owner_deadline_ms(), :millisecond), now) ==
      :lt
  end

  defp mark_checked(run, now, status \\ "running") do
    Run
    |> where([r], r.id == ^run.id and r.status == ^status)
    |> Repo.update_all(set: [reaper_checked_at: now])

    :ok
  end

  @doc """
  Stops the execution recorded as `owner_id`, wherever it runs, and reports
  whether its termination is established.

  The owner is local only when both its node and its boot id match this
  VM. An owner id naming this node with another boot id belongs to a
  previous incarnation or to another undistributed instance sharing the
  node name; it cannot be asked, so it is `{:retain, :foreign_boot}`.
  """
  @spec stop_owner(String.t() | nil) :: :terminated | {:retain, term()}
  def stop_owner(owner_id) do
    {owner_node, boot} = Executions.owner_location(owner_id)
    local_node = node()

    cond do
      owner_node == nil -> {:retain, :unknown_owner_node}
      owner_node != local_node -> stop_remote(owner_node, owner_id)
      boot == Executions.boot_id() -> interpret(Executions.stop(owner_id))
      true -> {:retain, :foreign_boot}
    end
  end

  defp stop_remote(owner_node, owner_id) do
    owner_node
    |> :erpc.call(Executions, :stop, [owner_id], @rpc_timeout_ms)
    |> interpret()
  rescue
    error -> {:retain, {:unreachable, Exception.message(error)}}
  catch
    kind, reason -> {:retain, {:unreachable, {kind, reason}}}
  end

  defp interpret(:not_running), do: :terminated
  defp interpret(:stopped), do: :terminated
  defp interpret(other), do: {:retain, other}

  ## Output retention

  defp purge_output(now) do
    cutoff = DateTime.add(now, -Config.output_retention_ms(), :millisecond)

    ids =
      RunStep
      |> where([s], not is_nil(s.output) and s.finished_at < ^cutoff)
      |> select([s], s.id)
      |> limit(@output_purge_batch)

    {count, _} =
      RunStep
      |> where([s], s.id in subquery(ids))
      |> Repo.update_all(set: [output: nil, updated_at: now])

    count
  end

  ## Operator escape hatch

  @doc """
  Operator escape hatch: fails a `running` run whose owner can no longer be
  investigated (for example, an owner id naming a node from before a
  redeploy that changed node names), releasing its active guard.

  Use only after establishing that the recorded owner's node is gone or
  its execution has stopped. This deliberately overrides the reaper's
  safety rule: a reachable live owner is still stopped first, but if its
  termination cannot be confirmed the run is cleared anyway, because the
  operator has taken responsibility. That case is logged as a warning, since
  a still-live worker could then hold the VM while a new run starts (it is
  fenced from further run writes and VM actions by its owner id).
  Finalization stays conditional on the run being `running` under the
  owner read here, so a run that completes concurrently is left alone.
  """
  @spec force_abandon(Ecto.UUID.t()) ::
          {:ok, Run.t()} | {:error, :not_found | :not_running}
  def force_abandon(run_id) do
    with {:ok, run_id} <- Ecto.UUID.cast(run_id),
         %Run{} = run <- Repo.get(Run, run_id) do
      force_abandon_run(run)
    else
      _ -> {:error, :not_found}
    end
  end

  defp force_abandon_run(%Run{status: "running"} = run) do
    owner_result = stop_owner(run.owner_id)

    Logger.warning(
      "Spry run #{run.id} force-abandoned by an operator " <>
        "(owner #{inspect(run.owner_id)}: #{inspect(owner_result)})"
    )

    if unconfirmed_reachable_owner?(owner_result) do
      Logger.warning(
        "Spry run #{run.id}: finalizing despite a reachable owner whose termination could not " <>
          "be confirmed; it may still be running its current VM action"
      )
    end

    error = "abandoned: an operator released this run after its owner could not be investigated"

    case Runner.finalize(run.id, run.owner_id, "failed", error, "abandoned") do
      :ok -> {:ok, Repo.get!(Run, run.id)}
      :noop -> {:error, :not_running}
    end
  end

  defp force_abandon_run(%Run{}), do: {:error, :not_running}

  defp unconfirmed_reachable_owner?(:terminated), do: false
  defp unconfirmed_reachable_owner?({:retain, reason}), do: not unreachable?(reason)

  defp finalize_abandoned(run, now) do
    error =
      "abandoned: the worker executing this run stopped before finishing#{pgflow_detail(run)}"

    case Runner.finalize(run.id, run.owner_id, "failed", error, "abandoned") do
      :ok ->
        :failed

      :noop ->
        mark_checked(run, now)
        :retained
    end
  end

  # PgFlow's view of the execution corroborates the investigation in the
  # error text; it is never treated as proof that the owner is gone.
  defp pgflow_detail(%Run{pgflow_run_id: nil}), do: ""

  defp pgflow_detail(%Run{pgflow_run_id: pgflow_run_id}) do
    case PgFlow.get_run(pgflow_run_id) do
      {:ok, %{status: status}} -> " (job status: #{status})"
      _ -> ""
    end
  rescue
    _ -> ""
  end
end
