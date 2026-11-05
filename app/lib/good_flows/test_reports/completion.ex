defmodule GoodFlows.TestReports.Completion do
  @moduledoc """
  Derives one report's completion status, independently of test outcomes
  and job status.

  A report is `"complete"` only when its last record is `suite_finished`
  with `aborted` false and `unfinished_tests` and `unfinished_groups` both
  zero, no `interrupted` or `max_failures_reached` record appears anywhere,
  and `report.truncated` is false. Every other accepted report is
  `"incomplete"`. Failed or errored tests and groups, or a failed job, do
  not make a report incomplete. Only core `test-timings/1` fields are read,
  never `meta`.

  This is a per-report claim only: a complete partition says nothing about
  whether the rest of its workflow invocation completed.
  """

  @typedoc "Per-report completion status."
  @type status :: String.t()

  @doc "Completion statuses, in a fixed order."
  @spec statuses() :: [status()]
  def statuses, do: ["complete", "incomplete"]

  @doc ~s(Returns `"complete"` or `"incomplete"` for a validated document.)
  @spec status(map()) :: status()
  def status(%{"report" => %{"truncated" => false, "records" => records}}) do
    if finished?(List.last(records)) and not Enum.any?(records, &marker?/1),
      do: "complete",
      else: "incomplete"
  end

  def status(_document), do: "incomplete"

  defp finished?(%{
         "event" => "suite_finished",
         "aborted" => false,
         "unfinished_tests" => 0,
         "unfinished_groups" => 0
       }),
       do: true

  defp finished?(_record), do: false

  defp marker?(%{"event" => event}), do: event in ["interrupted", "max_failures_reached"]
end
