defmodule GoodFlows.TestReports.Consistency do
  @moduledoc """
  Cross-record checks for a structurally valid test report, run by
  `GoodFlows.TestReports.Validator` after the structural pass.

    * every record's `run_id` equals `report.suite_id` and its `report_id`
      equals `report.report_id`
    * the first record is the only `suite_started`; a `suite_finished`, if
      present, is the only one and the last record
    * the envelope `partition` and `partition_count` equal the
      `suite_started` values
    * execution ids are unique; a finish event matches an open start of the
      same kind with identical start fields; starts may stay unmatched
    * a finished test's `duration_us` is an integer exactly when it passed
      or failed
    * the `suite_finished` unfinished counters, `counts`, `files` and
      `times_us` agree with the finished events, using the producer
      formatter's aggregation: test counts and durations come from
      `test_finished` events, module counts and observed durations from
      `module_finished` events, each grouped by file and by the event's
      `async` value (`true` → `async`, `false` → `sync`, `null` →
      `unknown`); missing durations count as zero and `counts` omit zeros

  Module-level `counts` are not compared with test events: ExUnit can omit
  excluded and skipped tests from them.
  """

  alias GoodFlows.TestReports.Validator

  @doc "Returns `{path, message}` errors for a structurally valid document."
  @spec check(map()) :: [GoodFlows.TestReports.Document.error()]
  def check(%{"report" => report}) do
    records = report["records"]
    count = length(records)

    initial = %{errors: [], open: %{}, used: MapSet.new(), tests: [], modules: []}

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

  defp add(state, path, message), do: %{state | errors: [{path, message} | state.errors]}

  defp identity(state, record, report, path) do
    state
    |> then(fn s ->
      if record["run_id"] == report["suite_id"],
        do: s,
        else: add(s, path ++ ["run_id"], "does not match report.suite_id")
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
       when event in ["test_started", "module_started"] do
    id = record["execution_id"]

    if MapSet.member?(state.used, id) do
      add(state, path ++ ["execution_id"], "is already used")
    else
      %{state | used: MapSet.put(state.used, id), open: Map.put(state.open, id, record)}
    end
  end

  defp execution(state, %{"event" => event} = record, path)
       when event in ["test_finished", "module_finished"] do
    id = record["execution_id"]
    started = start_event(event)

    case Map.fetch(state.open, id) do
      {:ok, %{"event" => ^started} = start} ->
        state = %{state | open: Map.delete(state.open, id)} |> finished(event, record, path)

        if Map.take(start, Validator.start_fields(event)) ==
             Map.take(record, Validator.start_fields(event)),
           do: state,
           else: add(state, path ++ ["execution_id"], "does not match its start event")

      _other ->
        add(state, path ++ ["execution_id"], "has no matching start event")
    end
  end

  defp execution(state, _record, _path), do: state

  defp start_event("test_finished"), do: "test_started"
  defp start_event("module_finished"), do: "module_started"

  defp finished(state, "test_finished", record, path) do
    executed? = record["outcome"] in ["passed", "failed"]
    duration = record["duration_us"]

    state =
      cond do
        executed? and is_nil(duration) ->
          add(state, path ++ ["duration_us"], "is required for passed and failed tests")

        not executed? and not is_nil(duration) ->
          add(state, path ++ ["duration_us"], "must be null unless the test passed or failed")

        true ->
          state
      end

    %{state | tests: [record | state.tests]}
  end

  defp finished(state, "module_finished", record, _path),
    do: %{state | modules: [record | state.modules]}

  defp partition(state, report, suite_started) do
    Enum.reduce(["partition", "partition_count"], state, fn key, state ->
      if report[key] == suite_started[key],
        do: state,
        else: add(state, ["report", key], "does not match suite_started")
    end)
  end

  defp summary(state, %{"event" => "suite_finished"} = final, index) do
    path = ["report", "records", index]
    open = Map.values(state.open)

    state
    |> expect(
      final["unfinished_tests"] == count_open(open, "test_started"),
      path,
      "unfinished_tests"
    )
    |> expect(
      final["unfinished_modules"] == count_open(open, "module_started"),
      path,
      "unfinished_modules"
    )
    |> expect(
      normalize_counts(final["counts"]) == tally(state.tests),
      path,
      "counts"
    )
    |> expect(files_match?(final["files"], state), path, "files")
    |> times(final["times_us"], path ++ ["times_us"])
  end

  defp summary(state, _record, _index), do: state

  defp expect(state, true, _path, _key), do: state

  defp expect(state, false, path, key),
    do: add(state, path ++ [key], "does not match the finished events")

  defp count_open(open, event), do: Enum.count(open, &(&1["event"] == event))

  defp times(state, times, path) do
    run = times["run"]

    state
    |> then(fn s ->
      if times["sync"] == run - (times["async"] || 0),
        do: s,
        else: add(s, path ++ ["sync"], "must equal run minus async")
    end)
    |> then(fn s ->
      if times["total"] == run + (times["load"] || 0),
        do: s,
        else: add(s, path ++ ["total"], "must equal run plus load")
    end)
  end

  ## Aggregation

  defp tally(tests) do
    Enum.reduce(tests, %{}, fn test, acc -> Map.update(acc, test["outcome"], 1, &(&1 + 1)) end)
  end

  defp normalize_counts(counts), do: Map.reject(counts, fn {_key, value} -> value == 0 end)

  defp files_match?(files, state) do
    provided = Enum.map(files, &normalize_file/1)
    by_file = Map.new(provided, &{&1["file"], &1})

    map_size(by_file) == length(provided) and by_file == expected_files(state)
  end

  defp normalize_file(file) do
    file
    |> Map.update!("counts", &normalize_counts/1)
    |> Map.new(fn
      {bucket, cost} when bucket in ["async", "sync", "unknown"] ->
        {bucket, Map.update!(cost, "counts", &normalize_counts/1)}

      pair ->
        pair
    end)
  end

  defp expected_files(state) do
    events =
      Enum.map(state.tests, &{&1, :test}) ++ Enum.map(state.modules, &{&1, :module})

    Enum.reduce(events, %{}, fn {event, kind}, files ->
      bucket = bucket(event["async"])

      file =
        Map.get_lazy(files, event["file"], fn ->
          Map.merge(empty_cost(), %{
            "file" => event["file"],
            "async" => empty_cost(),
            "sync" => empty_cost(),
            "unknown" => empty_cost()
          })
        end)

      file = file |> add_cost(kind, event) |> Map.update!(bucket, &add_cost(&1, kind, event))
      Map.put(files, event["file"], file)
    end)
  end

  defp bucket(true), do: "async"
  defp bucket(false), do: "sync"
  defp bucket(nil), do: "unknown"

  defp empty_cost do
    %{
      "test_count" => 0,
      "module_count" => 0,
      "counts" => %{},
      "test_duration_us" => 0,
      "observed_module_duration_us" => 0
    }
  end

  defp add_cost(cost, :test, event) do
    %{
      cost
      | "test_count" => cost["test_count"] + 1,
        "test_duration_us" => cost["test_duration_us"] + (event["duration_us"] || 0),
        "counts" => Map.update(cost["counts"], event["outcome"], 1, &(&1 + 1))
    }
  end

  defp add_cost(cost, :module, event) do
    %{
      cost
      | "module_count" => cost["module_count"] + 1,
        "observed_module_duration_us" =>
          cost["observed_module_duration_us"] + (event["observed_duration_us"] || 0)
    }
  end
end
