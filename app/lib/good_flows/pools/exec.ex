defmodule GoodFlows.Pools.Exec do
  @moduledoc """
  One command run on a leased member.

  Statuses: `running`, then `exited`, `timed_out`, `cancelled`, or `error`
  (with `error_reason`, e.g. `owner_lost`). A partial unique index allows at
  most one `running` exec per member.

  The command, argv, and env are never stored. The row keeps the bounded
  terminal exit payload so `exit` can be replayed after the `ExecServer`
  stops: `outputs` (at most 65,537 bytes of `GOODFLOWS_OUTPUT`),
  `outputs_truncated`, the report manifest (`reports`, a map with `files`,
  each `%{"name", "size", "too_large"}`), `collect_failed` (the
  post-exit read of outputs and reports failed, so both are missing),
  `final_output_seq` (the last
  output event's seq, -1 when there was none), `duration_ms`, and byte
  counts. `lease_generation` is the member lease it ran in, so report
  downloads can tell a later lease apart.
  """
  use Ecto.Schema

  alias GoodFlows.Pools.{Member, Session}

  @type t :: %__MODULE__{}

  @statuses ~w(running exited timed_out cancelled error)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pool_execs" do
    field :member_name, :string
    field :lease_generation, :integer
    field :job, :string
    field :step, :string
    field :status, :string, default: "running"
    field :exit_code, :integer
    field :outputs, :binary
    field :outputs_truncated, :boolean, default: false
    field :collect_reports, :boolean, default: false
    field :reports, :map
    field :reports_truncated, :boolean, default: false
    field :collect_failed, :boolean, default: false
    field :owner_id, :string
    field :operation_deadline_at, :utc_datetime_usec
    field :final_output_seq, :integer, default: -1
    field :error_reason, :string
    field :duration_ms, :integer
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :bytes_stdout, :integer, default: 0
    field :bytes_stderr, :integer, default: 0

    field :account_id, :binary_id
    belongs_to :session, Session
    belongs_to :member, Member

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every exec status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The report files listed for this exec (possibly empty)."
  @spec report_files(t()) :: [map()]
  def report_files(%__MODULE__{reports: %{"files" => files}}) when is_list(files), do: files
  def report_files(%__MODULE__{}), do: []

  @doc """
  The internal `exit` event: `exit_payload/1` plus `final_output_seq`, so a
  channel can push a `gap` for output it never received. Channels strip
  `final_output_seq` before pushing.
  """
  @spec exit_event(t()) :: map()
  def exit_event(%__MODULE__{} = exec),
    do: Map.put(exit_payload(exec), :final_output_seq, exec.final_output_seq)

  defp reports_skipped(%__MODULE__{reports: %{"skipped" => n}}) when is_integer(n), do: n
  defp reports_skipped(%__MODULE__{}), do: 0

  @doc """
  The `exit` event payload for an ended exec, from its persisted row.
  `outputs` is base64 (or nil when empty or missing). When `collect_failed`
  is set, `outputs` and `reports` are both nil: nothing was read, which is
  not the same as an empty outputs file or an empty report directory.
  """
  @spec exit_payload(t()) :: map()
  def exit_payload(%__MODULE__{} = exec) do
    %{
      exec_id: exec.id,
      status: exec.status,
      exit_code: if(exec.status == "exited", do: exec.exit_code),
      duration_ms: exec.duration_ms,
      error_reason: if(exec.status == "error", do: exec.error_reason),
      outputs:
        if(exec.collect_failed or exec.outputs in [nil, ""],
          do: nil,
          else: Base.encode64(exec.outputs)
        ),
      outputs_truncated: exec.outputs_truncated,
      collect_failed: exec.collect_failed,
      reports:
        if(exec.collect_reports and not exec.collect_failed,
          do: %{
            files: report_files(exec),
            truncated: exec.reports_truncated,
            skipped: reports_skipped(exec)
          }
        )
    }
  end
end
