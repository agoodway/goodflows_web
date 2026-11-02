defmodule GoodFlows.Spry.Config do
  @moduledoc """
  Runtime settings for Spry runs, read from `config :good_flows, GoodFlows.Spry`:

    * `:step_timeout_ms` - elapsed-time deadline for each VM action (default 30 minutes)
    * `:run_timeout_ms` - total execution budget per run from claim (default 6 hours)
    * `:output_limit_bytes` - stored tail of each step's output (default 64 KiB)
    * `:sprites_base_url` - Sprites API base URL (`nil` uses the SDK default)
    * `:queued_reap_after_ms` - age after which the reaper checks whether a
      still-`queued` run's PgFlow job is gone (default `nil`, meaning
      `run_timeout_ms` plus the finalization overhead)
    * `:output_retention_ms` - how long finished steps keep their `output`
      before the reaper sweep clears it (default 30 days)
    * `:require_named_node` - refuse to start PgFlow workers on a node that
      is not distributed (`:nonode@nohost`); set in production by
      `config/runtime.exs` (default `false`)

  The PgFlow hard timeout for `GoodFlows.Spry.RunJob` is fixed at compile time
  (`job_timeout_seconds/0`). `validate!/0` runs at startup and refuses a total
  run budget that the job timeout cannot cover with 5 minutes to spare.
  """

  @defaults [
    step_timeout_ms: 30 * 60_000,
    run_timeout_ms: 6 * 60 * 60_000,
    output_limit_bytes: 65_536,
    sprites_base_url: nil,
    queued_reap_after_ms: nil,
    output_retention_ms: 30 * 24 * 60 * 60_000,
    require_named_node: false
  ]

  @job_timeout_seconds 21_900
  @finalization_overhead_ms 5 * 60_000

  @doc "PgFlow hard timeout, in seconds, for the run job."
  @spec job_timeout_seconds() :: pos_integer()
  def job_timeout_seconds, do: @job_timeout_seconds

  @doc "Time reserved beyond the run budget for cleanup and finalization."
  @spec finalization_overhead_ms() :: pos_integer()
  def finalization_overhead_ms, do: @finalization_overhead_ms

  @doc "Per-action elapsed-time deadline in milliseconds."
  @spec step_timeout_ms() :: pos_integer()
  def step_timeout_ms, do: get(:step_timeout_ms)

  @doc "Total run budget in milliseconds."
  @spec run_timeout_ms() :: pos_integer()
  def run_timeout_ms, do: get(:run_timeout_ms)

  @doc "Maximum stored bytes of step output."
  @spec output_limit_bytes() :: pos_integer()
  def output_limit_bytes, do: get(:output_limit_bytes)

  @doc "Sprites API base URL override, or `nil` for the SDK default."
  @spec sprites_base_url() :: String.t() | nil
  def sprites_base_url, do: get(:sprites_base_url)

  @doc """
  Age (ms) after which a `queued` run is checked against its PgFlow job.
  Defaults to the run budget plus the finalization overhead, so a run that
  waits for worker capacity is never mistaken for a lost one too early.
  """
  @spec queued_reap_after_ms() :: pos_integer()
  def queued_reap_after_ms do
    get(:queued_reap_after_ms) || run_timeout_ms() + @finalization_overhead_ms
  end

  @doc "How long (ms) finished steps keep their stored output."
  @spec output_retention_ms() :: pos_integer()
  def output_retention_ms, do: get(:output_retention_ms)

  @doc """
  Time (ms) after a run's claim by which its execution has certainly ended:
  the PgFlow hard timeout plus the finalization overhead. Past it, the
  reaper treats an owner it cannot reach as terminated.
  """
  @spec owner_deadline_ms() :: pos_integer()
  def owner_deadline_ms, do: @job_timeout_seconds * 1_000 + @finalization_overhead_ms

  @doc "Whether PgFlow workers may only start on a distributed (named) node."
  @spec require_named_node?() :: boolean()
  def require_named_node?, do: get(:require_named_node) == true

  @doc """
  Raises unless the settings are positive integers, the job timeout covers
  the run budget plus the finalization overhead, and (when
  `:require_named_node` is set and PgFlow is configured) the node is named.
  """
  @spec validate!(pos_integer(), keyword()) :: :ok
  def validate!(job_timeout_seconds \\ @job_timeout_seconds, opts \\ []) do
    for key <- [:step_timeout_ms, :run_timeout_ms, :output_limit_bytes, :output_retention_ms] do
      ensure_positive!(key, get(key))
    end

    if get(:queued_reap_after_ms) != nil,
      do: ensure_positive!(:queued_reap_after_ms, get(:queued_reap_after_ms))

    required_ms = run_timeout_ms() + @finalization_overhead_ms

    if job_timeout_seconds * 1_000 < required_ms do
      raise ArgumentError,
            "GoodFlows.Spry.RunJob timeout (#{job_timeout_seconds}s) must cover run_timeout_ms " <>
              "(#{run_timeout_ms()}ms) plus #{div(@finalization_overhead_ms, 1_000)}s of finalization"
    end

    validate_node!(
      Keyword.get(opts, :node, node()),
      Keyword.get_lazy(opts, :pgflow?, fn -> is_list(Application.get_env(:good_flows, PgFlow)) end)
    )
  end

  defp validate_node!(:nonode@nohost, true = _pgflow?) do
    if require_named_node?() do
      raise ArgumentError,
            "Spry workers need a distributed node with a stable name so run owners can be " <>
              "investigated; start the release with RELEASE_DISTRIBUTION=name and RELEASE_NODE " <>
              "(see rel/env.sh.eex)"
    end

    :ok
  end

  defp validate_node!(_node, _pgflow?), do: :ok

  defp ensure_positive!(key, value) do
    unless is_integer(value) and value > 0 do
      raise ArgumentError,
            "config :good_flows, GoodFlows.Spry, #{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp get(key) do
    :good_flows
    |> Application.get_env(GoodFlows.Spry, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end
end
