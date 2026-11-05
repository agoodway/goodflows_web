defmodule GoodFlows.TestReports.Consistency do
  @moduledoc """
  Cross-record checks for a structurally valid test report, run by
  `GoodFlows.TestReports.Validator` after the structural pass. They mirror
  `Validator::push` in goodflows `src/reporting/collect.rs`:

    * every record's `suite_id` equals `report.suite_id` and its
      `report_id` equals `report.report_id`
    * the first record is the only `suite_started`; a `suite_finished`, if
      present, is the only one and the last record
    * the envelope `partition` and `partition_count` equal the
      `suite_started` values
    * groups and tests are paired separately: an `execution_id` is used at
      most once among `group_started` events and separately at most once
      among `test_started` events; a finish event closes an open start of
      its own kind with identical core keys (`Validator.start_fields/1`);
      common keys and `meta` may differ, and starts may stay unmatched
    * `suite_finished.unfinished_tests` and `unfinished_groups` equal the
      number of starts of each kind left open

  Nothing else is compared. In particular `counts` are not tallied against
  the finished events (a retried test is written once per attempt and
  counted once), and `duration_us` is not tied to `outcome`.

  goodflows stops at the first bad record and rejects any record after a
  `suite_finished` as out of order; reporting a `suite_finished` that is
  not last rejects exactly the same documents.
  """

  alias GoodFlows.TestReports.Validator

  @doc "Returns `{path, message}` errors for a structurally valid document."
  @spec check(map()) :: [GoodFlows.TestReports.Document.error()]
  def check(%{"report" => report}) do
    records = report["records"]
    count = length(records)

    initial = %{errors: [], groups: new_kind(), tests: new_kind()}

    state =
      records
      |> Enum.with_index()
      |> Enum.reduce(initial, fn {record, index}, state ->
        path = ["report", "records", index]

        state
        |> identity(record, report, path)
        |> position(record, index, count, path)
        |> execution(record, path)
      end)

    state
    |> partition(report, hd(records))
    |> summary(List.last(records), count - 1)
    |> Map.fetch!(:errors)
    |> Enum.reverse()
  end

  defp new_kind, do: %{open: %{}, used: MapSet.new()}

  defp add(state, path, message), do: %{state | errors: [{path, message} | state.errors]}

  defp identity(state, record, report, path) do
    state
    |> then(fn s ->
      if record["suite_id"] == report["suite_id"],
        do: s,
        else: add(s, path ++ ["suite_id"], "does not match report.suite_id")
    end)
    |> then(fn s ->
      if record["report_id"] == report["report_id"],
        do: s,
        else: add(s, path ++ ["report_id"], "does not match report.report_id")
    end)
  end

  defp position(state, %{"event" => "suite_started"}, 0, _count, _path), do: state

  defp position(state, %{"event" => "suite_started"}, _index, _count, path),
    do: add(state, path ++ ["event"], "must only be the first record")

  defp position(state, _record, 0, _count, path),
    do: add(state, path ++ ["event"], "must be suite_started")

  defp position(state, %{"event" => "suite_finished"}, index, count, path)
       when index != count - 1,
       do: add(state, path ++ ["event"], "must be the last record")

  defp position(state, _record, _index, _count, _path), do: state

  defp execution(state, %{"event" => event} = record, path)
       when event in ["group_started", "test_started"] do
    kind = kind(event)
    %{open: open, used: used} = Map.fetch!(state, kind)
    id = record["execution_id"]

    if MapSet.member?(used, id) do
      add(state, path ++ ["execution_id"], "is already used")
    else
      Map.put(state, kind, %{open: Map.put(open, id, record), used: MapSet.put(used, id)})
    end
  end

  defp execution(state, %{"event" => event} = record, path)
       when event in ["group_finished", "test_finished"] do
    kind = kind(event)
    %{open: open} = slot = Map.fetch!(state, kind)
    id = record["execution_id"]

    case Map.pop(open, id) do
      {nil, _open} ->
        add(state, path ++ ["execution_id"], "has no matching start event")

      {start, open} ->
        state = Map.put(state, kind, %{slot | open: open})
        keys = Validator.start_fields(event)

        if Map.take(start, keys) == Map.take(record, keys),
          do: state,
          else: add(state, path ++ ["execution_id"], "does not match its start event")
    end
  end

  defp execution(state, _record, _path), do: state

  defp kind(event) when event in ["group_started", "group_finished"], do: :groups
  defp kind(event) when event in ["test_started", "test_finished"], do: :tests

  # Compared only when the first record is a `suite_started`; otherwise
  # that record already has its ordering error and there is nothing to
  # compare with.
  defp partition(state, report, %{"event" => "suite_started"} = suite_started) do
    Enum.reduce(["partition", "partition_count"], state, fn key, state ->
      if report[key] == suite_started[key],
        do: state,
        else: add(state, ["report", key], "does not match suite_started")
    end)
  end

  defp partition(state, _report, _first), do: state

  defp summary(state, %{"event" => "suite_finished"} = final, index) do
    path = ["report", "records", index]

    Enum.reduce([{"unfinished_tests", :tests}, {"unfinished_groups", :groups}], state, fn
      {key, kind}, state ->
        if final[key] == map_size(Map.fetch!(state, kind).open),
          do: state,
          else: add(state, path ++ [key], "does not match the open start events")
    end)
  end

  defp summary(state, _record, _index), do: state
end
