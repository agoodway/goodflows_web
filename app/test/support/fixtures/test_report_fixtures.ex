defmodule GoodFlows.TestReportFixtures do
  @moduledoc """
  Synthetic `exunit-timings` test reports for the test report ingestion
  contract (design D1 of `store-test-timings`).

  The JSON files in `test/support/fixtures/test_reports/` are the frozen
  contract samples shared with the publisher (`goodci`) and producer
  (`goodcases`) companion changes:

    * `complete.json` – a passing partition with every completed-run event
      kind and nested file totals
    * `failed.json` – a complete partition with a failed test and a failed job
    * `incomplete.json` – a cancelled partition with `max_failures_reached`,
      an unmatched `test_started` and `interrupted`, and no `suite_finished`

  They are synthetic: no logs, assertion data, failure payloads, parameter
  values or project slug.
  """

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Projects.Project
  alias GoodFlows.TestReports

  @dir Path.expand("test_reports", __DIR__)
  @names ~w(complete failed incomplete)

  for name <- @names, do: @external_resource(Path.join(@dir, name <> ".json"))

  @doc "Fixture names."
  def names, do: @names

  @doc "The raw JSON body of fixture `name`."
  def report_json(name) when name in @names, do: File.read!(Path.join(@dir, name <> ".json"))

  @doc "Fixture `name` decoded to plain maps, with `overrides` deep-merged in."
  def report(name, overrides \\ %{}) do
    name |> report_json() |> Jason.decode!() |> deep_merge(overrides)
  end

  @doc "Puts `value` at `path` (keys and list indexes) in `document`."
  def put_at(document, [key], value) when is_integer(key),
    do: List.replace_at(document, key, value)

  def put_at(document, [key], value), do: Map.put(document, key, value)

  def put_at(document, [key | rest], value) when is_integer(key),
    do: List.update_at(document, key, &put_at(&1, rest, value))

  def put_at(document, [key | rest], value),
    do: Map.update!(document, key, &put_at(&1, rest, value))

  @doc "Removes the key at `path` in `document`."
  def delete_at(document, [key]), do: Map.delete(document, key)

  def delete_at(document, [key | rest]) when is_integer(key),
    do: List.update_at(document, key, &delete_at(&1, rest))

  def delete_at(document, [key | rest]), do: Map.update!(document, key, &delete_at(&1, rest))

  @doc "Records of `document`."
  def records(document), do: document["report"]["records"]

  @doc "Replaces the records of `document`."
  def with_records(document, records), do: put_at(document, ["report", "records"], records)

  @doc """
  Re-identifies `document` as `report_id`: the envelope and every record get
  the new id, so the result is a distinct, valid report.
  """
  def with_report_id(document, report_id) do
    records = Enum.map(records(document), &Map.put(&1, "report_id", report_id))

    document
    |> put_at(["report", "report_id"], report_id)
    |> with_records(records)
  end

  @doc """
  A valid, complete report of exactly `records` records (an even number of
  at least 4): `suite_started`, `(records - 2) / 2` passed async tests in
  one file, and a consistent `suite_finished`. Each test's `describe` is
  padded so the JSON encoding is as close to `bytes` as possible without
  exceeding it (it is never smaller than the unpadded report).
  """
  def large_report(records, bytes) when rem(records, 2) == 0 and records >= 4 do
    tests = div(records - 2, 2)
    base = large_report_with_padding(tests, 0)
    unpadded = base |> Jason.encode!() |> byte_size()

    # `describe` appears in both events of a test; each padding byte also
    # turns `null` into a string, which costs 2 bytes ("") minus 4 (null).
    per_test = max(div(bytes - unpadded + 4 * tests, 2 * tests) - 2, 0)
    report = large_report_with_padding(tests, per_test)
    size = report |> Jason.encode!() |> byte_size()

    if size > bytes and per_test > 0,
      do: large_report_with_padding(tests, per_test - 1),
      else: report
  end

  defp large_report_with_padding(tests, padding) do
    base = report("complete")
    [suite_started | _] = records(base)
    suite_finished = List.last(records(base))
    describe = if padding == 0, do: nil, else: String.duplicate("d", padding)

    common = %{
      "run_id" => suite_started["run_id"],
      "report_id" => suite_started["report_id"]
    }

    test_records =
      Enum.flat_map(1..tests, fn id ->
        started =
          Map.merge(common, %{
            "event" => "test_started",
            "received_offset_us" => id,
            "module" => "M",
            "name" => "t#{id}",
            "description" => nil,
            "file" => "t.exs",
            "line" => 1,
            "describe" => describe,
            "async" => true,
            "parameter_id" => nil,
            "execution_id" => id,
            "started_offset_us" => id
          })

        [
          started,
          Map.merge(started, %{
            "event" => "test_finished",
            "duration_us" => 1,
            "outcome" => "passed"
          })
        ]
      end)

    cost = fn count ->
      %{
        "test_count" => count,
        "module_count" => 0,
        "counts" => if(count == 0, do: %{}, else: %{"passed" => count}),
        "test_duration_us" => count,
        "observed_module_duration_us" => 0
      }
    end

    file =
      tests
      |> cost.()
      |> Map.merge(%{
        "file" => "t.exs",
        "async" => cost.(tests),
        "sync" => cost.(0),
        "unknown" => cost.(0)
      })

    finished =
      Map.merge(suite_finished, %{
        "counts" => %{"passed" => tests},
        "files" => [file],
        "received_offset_us" => tests + 1
      })

    with_records(base, [suite_started | test_records] ++ [finished])
  end

  @doc "Validates and stores fixture `name` (or a document) for `project`."
  def stored_report_fixture(%Account{} = account, %Project{} = project, document \\ "complete") do
    document = if is_binary(document), do: report(document), else: document
    {:ok, ack} = TestReports.ingest(account, project, nil, document)
    ack
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right
end
