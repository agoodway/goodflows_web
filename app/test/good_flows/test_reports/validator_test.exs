defmodule GoodFlows.TestReports.ValidatorTest do
  use ExUnit.Case, async: true

  import GoodFlows.TestReportFixtures

  alias GoodFlows.TestReports.{Completion, Document, Validator}
  alias GoodFlowsWeb.Schemas.TestReportRequest

  defp validate(document), do: Validator.validate(document)

  defp validate_json(json) do
    {:ok, decoded} = Document.decode(json)
    Validator.validate(decoded)
  end

  defp errors(document) do
    assert {:error, {:invalid, errors}} = validate(document)
    errors
  end

  defp assert_error(document, path, message \\ nil) do
    errors = errors(document)
    assert Map.has_key?(errors, path), "expected an error on #{path}, got #{inspect(errors)}"
    if message, do: assert(message in errors[path], inspect(errors))
    errors
  end

  # Accepted, and stored exactly as supplied.
  defp assert_accepted(document, status \\ nil) do
    assert {:ok, accepted, derived} = validate(document)
    assert accepted == document
    if status, do: assert(derived == status)
    accepted
  end

  defp record_index(document, event) do
    Enum.find_index(records(document), &(&1["event"] == event))
  end

  defp record_path(index, key), do: ["report", "records", index, key]
  defp rendered(index, key), do: "report.records[#{index}].#{key}"

  # Sets `key` on both events of the test (or group) whose start is at
  # `started`, so the pair still matches.
  defp put_pair(document, started, key, value) do
    id = Enum.at(records(document), started)["execution_id"]
    kind = Enum.at(records(document), started)["event"] |> String.replace("_started", "")

    finished =
      Enum.find_index(
        records(document),
        &(&1["event"] == kind <> "_finished" and &1["execution_id"] == id)
      )

    document
    |> put_at(record_path(started, key), value)
    |> put_at(record_path(finished, key), value)
  end

  defp put_meta(document, index, meta), do: put_at(document, record_path(index, "meta"), meta)

  defp suite_finished_index(document), do: length(records(document)) - 1

  describe "contract fixtures" do
    test "every fixture is accepted with its derived status" do
      for {name, status} <- [
            {"complete", "complete"},
            {"failed", "complete"},
            {"incomplete", "incomplete"}
          ] do
        assert {:ok, document, ^status} = validate_json(report_json(name)), name
        assert document == report(name)
      end
    end

    test "fixtures carry no project, logs, assertion, failure or parameter values" do
      forbidden =
        ~w(project account_id log logs message stacktrace assertion error failure parameters
           tags output)

      for name <- names() do
        keys = name |> report() |> all_keys()

        for key <- forbidden,
            do: refute(key in keys, "#{name} has a #{inspect(key)} key")
      end
    end

    test "fixtures together use every event kind, null filters, a retry and an errored group" do
      all = Enum.flat_map(names(), &records(report(&1)))
      events = Enum.map(all, & &1["event"])
      assert Enum.sort(Enum.uniq(events)) == Enum.sort(Validator.events())

      failed = records(report("failed"))
      assert hd(failed)["filters"] == nil

      retried =
        failed
        |> Enum.filter(&(&1["event"] == "test_finished"))
        |> Enum.group_by(&{&1["group"], &1["path"], &1["name"]})
        |> Enum.find(fn {_identity, attempts} -> length(attempts) > 1 end)

      assert {_identity, [_, _]} = retried
      assert Enum.any?(failed, &(&1["event"] == "group_finished" and &1["outcome"] == "errored"))

      assert Enum.any?(
               failed,
               &(&1["event"] == "test_started" and length(&1["path"]) > 1)
             )
    end

    # Hand-written, but shaped like what goodflows' reporters emit
    # (`reporters/exunit/lib/goodflows/ex_unit_reporter.ex`,
    # `reporters/jest/index.js`).
    test "fixture meta follows the goodflows reporters" do
      for name <- names() do
        suite_meta = hd(records(report(name)))["meta"]

        for key <- ~w(reporter reporter_version filtered),
            do: assert(Map.has_key?(suite_meta, key), "#{name} suite_started.meta lacks #{key}")

        assert is_boolean(suite_meta["filtered"])

        # Neither reporter writes meta on these markers.
        for %{"event" => event} = record <- records(report(name)),
            event in ["interrupted", "max_failures_reached"],
            do: refute(Map.has_key?(record, "meta"), "#{name} #{event} has meta")
      end

      for name <- ["complete", "incomplete"] do
        records = records(report(name))
        assert hd(records)["runner"]["name"] == "exunit"

        assert %{"reporter" => "goodflows_exunit_reporter"} = hd(records)["meta"]

        for key <- ~w(elixir_version otp_release max_cases schedulers),
            do: assert(Map.has_key?(hd(records)["meta"], key))

        for %{"event" => event} = record <- records,
            event in ["group_started", "group_finished"],
            do:
              assert(Map.keys(record["meta"]) |> Enum.sort() == ~w(async parameter_id setup_all))

        for %{"event" => event} = record <- records,
            event in ["test_started", "test_finished"] do
          assert %{"async" => _, "parameter_id" => _} = record["meta"]
          # ExUnit's `test ` prefix is not part of `name`; `path` is one describe.
          refute String.starts_with?(record["name"], "test ")
          assert length(record["path"]) <= 1
        end

        for %{"event" => "test_finished", "outcome" => "skipped"} = record <- records,
            do: assert(record["meta"]["skip_reason"] in ["skipped", "excluded"])
      end

      jest = records(report("failed"))
      assert hd(jest)["runner"]["name"] == "jest"

      assert %{
               "reporter" => "goodflows-jest-reporter",
               "duration_resolution_us" => 1000,
               "node_version" => _,
               "max_workers" => _
             } = hd(jest)["meta"]

      for %{"event" => event} = record <- jest, event in ["test_started", "test_finished"] do
        # Jest writes `line` only as `test_finished.meta.line`.
        assert record["line"] == nil
        if event == "test_started", do: refute(Map.has_key?(record, "meta"))
      end

      finished = for %{"event" => "test_finished"} = record <- jest, do: record
      # `invocations` only when Jest reports more than one.
      assert Enum.all?(finished, &(Map.get(&1["meta"], "invocations", 2) > 1))
      assert Enum.any?(finished, &(&1["meta"]["invocations"] == 2))

      # Jest numbers groups and tests from one counter, so they never share an id.
      ids = for %{"event" => e, "execution_id" => id} <- jest, e =~ "_started", do: id
      assert ids == Enum.uniq(ids)
    end

    test "the OpenAPI request example is a valid report" do
      example = TestReportRequest.schema().example
      assert {:ok, _document, "complete"} = validate(example)
    end
  end

  describe "the server accepts exactly what goodflows collection accepts" do
    test "a retried test counted once is accepted" do
      failed = report("failed")
      assert hd(records(failed))["runner"]["name"] == "jest"
      assert_accepted(failed, "complete")
    end

    test "counts that disagree with test events are accepted and stored unchanged" do
      complete = report("complete")
      index = suite_finished_index(complete)

      document = put_at(complete, record_path(index, "counts"), %{"passed" => 99, "errored" => 0})
      assert_accepted(document, "complete")

      group = record_index(complete, "group_finished")
      assert_accepted(put_at(complete, record_path(group, "counts"), %{"failed" => 7}))
    end

    test "any duration is accepted for any outcome" do
      complete = report("complete")

      skipped =
        Enum.find_index(records(complete), &(&1["outcome"] == "skipped"))

      passed = Enum.find_index(records(complete), &(&1["outcome"] == "passed"))

      assert_accepted(put_at(complete, record_path(skipped, "duration_us"), 0))
      assert_accepted(put_at(complete, record_path(passed, "duration_us"), nil))
    end

    test "absolute and parent-relative file paths are accepted" do
      complete = report("complete")
      started = record_index(complete, "test_started")
      group = record_index(complete, "group_started")

      for file <- ["/src/app/test/a_test.exs", "../a.test.js", "C:\\x.exs", "~/x.exs"] do
        assert_accepted(put_pair(complete, started, "file", file))
        assert_accepted(put_pair(complete, group, "file", file))
      end
    end

    test "unknown nonexecuted metadata is accepted without fabricated cost" do
      complete = report("complete")

      excluded =
        Enum.find(
          records(complete),
          &(&1["event"] == "test_finished" and &1["outcome"] == "skipped" and is_nil(&1["file"]))
        )

      assert %{"duration_us" => nil, "file" => nil, "line" => nil} = excluded
      assert_accepted(complete)
    end

    test "a duration longer than the receipt interval is accepted unchanged" do
      complete = report("complete")
      index = record_index(complete, "test_finished")
      record = Enum.at(records(complete), index)
      long = record["received_offset_us"] - record["started_offset_us"] + 1_000_000

      assert_accepted(put_at(complete, record_path(index, "duration_us"), long))
    end
  end

  # Ported one-for-one from goodflows `src/reporting/contract.rs` tests
  # `field_types_follow_the_table` and `runner_metadata_is_flat_and_bounded`
  # (at `Validator.contract_version/0`): each vector is placed in a valid
  # report at a field of that type, and must be accepted or rejected as
  # goodflows does.
  describe "goodflows contract.rs vectors" do
    defp field_vectors do
      max = Document.max_integer()

      [
        {:text, "x", true},
        {:text, "", false},
        {:text, nil, false},
        {:text, String.duplicate("m", 4096), true},
        {:text, String.duplicate("é", 2049), false},
        {:opt_text, nil, true},
        {:opt_text, 1, false},
        {:identifier, "a b", false},
        {:timestamp, "2026-11-01T00:00:00Z", true},
        {:timestamp, "2026-11-01T00:00:00.123456Z", true},
        {:timestamp, "2026-11-01T00:00:00+00:00", true},
        {:timestamp, "2026-11-01T00:00:00+01:00", false},
        {:timestamp, "2026-02-30T00:00:00Z", false},
        {:timestamp, "2026-11-01", false},
        {:timestamp, "2026-11-01T00:00:00." <> String.duplicate("1", 50) <> "Z", false},
        {:uint, 0, true},
        {:uint, -1, false},
        {:uint, "12", false},
        {:uint, max, true},
        {:opt_uint, nil, true},
        {:opt_uint, -5, false},
        {:opt_int, -1843, true},
        {:opt_int, nil, true},
        {:opt_int, -max - 1, false},
        {:opt_int, true, false},
        {:bool, false, true},
        {:bool, 0, false},
        {:partition, "p.1_a-B", true},
        {:partition, "a b", false},
        {:partition, 1, false},
        {:partition, String.duplicate("x", 65), false},
        {:partition_count, nil, true},
        {:partition_count, 0, false},
        {:execution_id, 1, true},
        {:execution_id, 0, false},
        {:execution_id, nil, false},
        {:line, nil, true},
        {:line, 0, false},
        {:outcome, "errored", true},
        {:outcome, "todo", false},
        {:outcome, "excluded", false},
        {:counts, %{}, true},
        {:counts, %{"passed" => 1, "errored" => 0}, true},
        {:counts, %{"excluded" => 1}, false},
        {:counts, %{"passed" => -1}, false},
        {:counts, [], false},
        {:path, [], true},
        {:path, ["math", "sum"], true},
        {:path, List.duplicate("d", 32), true},
        {:path, List.duplicate("d", 33), false},
        {:path, [""], false},
        {:path, nil, false},
        {:runner, %{"name" => "jest", "version" => "30.0.0"}, true},
        {:runner, %{"name" => "exunit", "version" => nil}, true},
        {:runner, %{"name" => "jest runner", "version" => nil}, false},
        {:runner, %{"name" => "jest"}, false},
        {:runner, %{"name" => "jest", "version" => nil, "x" => 1}, false},
        {:runner, %{"name" => "jest", "version" => String.duplicate("1", 129)}, false},
        {:filters, nil, true},
        {:filters, %{"include" => [], "exclude" => []}, true},
        {:filters, %{"include" => []}, false},
        {:filters, [], false},
        {:filters, %{"include" => [], "exclude" => [], "x" => 1}, false},
        {:filters,
         %{"include" => [%{"tag" => "slow", "value" => true, "note" => "x"}], "exclude" => []},
         false},
        {:format, "test-timings/1", true},
        {:format, "exunit-timings", false},
        {:format, "test-timings/2", false}
      ]
    end

    defp meta_vectors do
      max = Document.max_integer()
      keys = fn n -> Map.new(0..(n - 1)//1, &{"k#{&1}", 1}) end

      [
        {%{"elixir_version" => "1.20.0", "otp_release" => "28", "max_cases" => 16}, true},
        {%{}, true},
        {%{"a" => nil, "b" => true, "c" => -max}, true},
        {%{"tags" => ["a", "b"]}, false},
        {%{"x" => %{"x" => 1}}, false},
        {keys.(32), true},
        {keys.(33), false},
        {%{"s" => String.duplicate("s", 256)}, true},
        {%{"s" => String.duplicate("s", 257)}, false},
        {%{"skip reason" => "x"}, false},
        {%{"" => 1}, false},
        {%{"n" => max + 1}, false},
        {[], false},
        {nil, false}
      ]
    end

    # Puts `value` at a field of `type` in the complete fixture, keeping
    # everything else valid (paired events and partition agreement too).
    defp place(type, value) do
      complete = report("complete")

      case Map.fetch!(placements(complete), type) do
        {:pair, key} ->
          put_pair(complete, record_index(complete, "test_started"), key, value)

        {:partition, key} ->
          complete |> put_at(["report", key], value) |> put_at(record_path(0, key), value)

        path ->
          put_at(complete, path, value)
      end
    end

    defp placements(complete) do
      finish = record_index(complete, "test_finished")
      last = suite_finished_index(complete)

      %{
        text: {:pair, "name"},
        opt_text: {:pair, "file"},
        execution_id: {:pair, "execution_id"},
        line: {:pair, "line"},
        path: {:pair, "path"},
        partition: {:partition, "partition"},
        partition_count: {:partition, "partition_count"},
        identifier: record_path(0, "runner") ++ ["name"],
        timestamp: record_path(0, "started_at"),
        uint: record_path(1, "received_offset_us"),
        opt_uint: record_path(finish, "duration_us"),
        opt_int: record_path(0, "seed"),
        bool: record_path(last, "aborted"),
        outcome: record_path(finish, "outcome"),
        counts: record_path(last, "counts"),
        runner: record_path(0, "runner"),
        filters: record_path(0, "filters"),
        format: record_path(0, "format")
      }
    end

    test "field_types_follow_the_table" do
      for {type, value, accepted?} <- field_vectors() do
        result = validate(place(type, value))

        if accepted?,
          do:
            assert(match?({:ok, _, _}, result), "#{type} #{inspect(value)}: #{inspect(result)}"),
          else: assert(match?({:error, {:invalid, _}}, result), "#{type} #{inspect(value)}")
      end
    end

    test "runner_metadata_is_flat_and_bounded" do
      for {meta, accepted?} <- meta_vectors() do
        result = validate(put_meta(report("complete"), 2, meta))

        if accepted? do
          assert {:ok, _, _} = result
        else
          assert {:error, {:invalid, errors}} = result, inspect(meta)
          assert Map.keys(errors) == ["report.records[2].meta"], inspect({meta, errors})
        end
      end
    end
  end

  describe "the format names its contract version" do
    test "the current format is accepted" do
      assert Validator.format() == "test-timings/1"
      assert Validator.contract_version() == "2026-11-04-generalize-test-timings"
      assert report("complete")["format"] == "test-timings/1"
      assert hd(records(report("complete")))["format"] == "test-timings/1"
    end

    test "a retired envelope format is the only error" do
      # A whole retired-format body: the envelope and its first record.
      retired =
        report("complete")
        |> Map.put("format", "exunit-timings")
        |> put_at(record_path(0, "format"), "exunit-timings")
        |> put_at(record_path(0, "run_id"), "suite-20261101-a")
        |> put_at(record_path(0, "max_cases"), 16)

      assert errors(retired) == %{"format" => ["is invalid"]}

      for format <- ["junit", "test-timings/2", nil, 1] do
        assert errors(Map.put(report("complete"), "format", format)) == %{
                 "format" => ["is invalid"]
               }
      end
    end

    test "a retired suite_started format is the only error" do
      for format <- ["test-timings/2", "exunit-timings", nil] do
        document =
          report("complete")
          |> put_at(record_path(0, "format"), format)
          |> put_at(record_path(1, "module"), "x")

        assert errors(document) == %{"report.records[0].format" => ["is invalid"]}
      end
    end

    test "the format error comes before every encoding error" do
      json =
        ~s({"format":"exunit-timings","x":{"a":1,"a":2},"n":99999999999999999999,) <>
          ~s("s":"\\u0000","report":{"records":[{"event":"suite_started"}]}})

      assert {:error, {:invalid, errors}} = validate_json(json)
      assert errors == %{"format" => ["is invalid"]}

      record =
        ~s({"format":"test-timings/1","x":{"a":1,"a":2},"n":99999999999999999999,) <>
          ~s("report":{"records":[{"event":"suite_started","format":"test-timings/2",) <>
          ~s("seed":-0,"meta":{"k":"\\u0000"}}]}})

      assert {:error, {:invalid, errors}} = validate_json(record)
      assert errors == %{"report.records[0].format" => ["is invalid"]}

      # Plain maps are read the same way.
      plain = %{"format" => "exunit-timings", "n" => Document.max_integer() + 1}
      assert errors(plain) == %{"format" => ["is invalid"]}
    end

    test "format_rejection/1 names the field and whether the format is the retired one" do
      complete = report("complete")
      assert Validator.format_rejection(complete) == nil
      assert Validator.format_rejection(Map.delete(complete, "format")) == nil

      assert Validator.format_rejection(Map.put(complete, "format", "exunit-timings")) ==
               {["format"], :retired}

      assert Validator.format_rejection(Map.put(complete, "format", "junit")) ==
               {["format"], :other}

      assert Validator.format_rejection(put_at(complete, record_path(0, "format"), 2)) ==
               {["report", "records", 0, "format"], :other}

      assert {:ok, decoded} = Document.decode(~s({"format":"exunit-timings"}))
      assert Validator.format_rejection(decoded) == {["format"], :retired}

      for not_a_report <- [nil, [], "x", 1, %{"report" => []}, %{"report" => %{"records" => 1}}],
          do: assert(Validator.format_rejection(not_a_report) == nil)
    end

    # Design D5: the suite_started rule applies whether the envelope format
    # is correct or missing, so the missing envelope format is not reported.
    test "a missing envelope format beside a retired record format reports only the record" do
      document =
        report("complete")
        |> Map.delete("format")
        |> put_at(record_path(0, "format"), "exunit-timings")

      assert errors(document) == %{"report.records[0].format" => ["is invalid"]}
    end

    test "a missing format is required" do
      assert_error(Map.delete(report("complete"), "format"), "format", "is required")

      assert_error(
        delete_at(report("complete"), record_path(0, "format")),
        rendered(0, "format"),
        "is required"
      )
    end

    test "a first record that is not suite_started is an ordering error, format unread" do
      complete = report("complete")
      [_first | rest] = records(complete)

      # Only the ordering error: in particular no partition mismatch
      # against a first record that is not suite_started.
      assert errors(with_records(complete, rest)) == %{
               "report.records[0].event" => ["must be suite_started"]
             }

      # A retired format on a first record that is not suite_started is not
      # the single format error: that record is checked like any other.
      first = put_at(hd(rest), ["format"], "exunit-timings")
      errors = errors(with_records(complete, [first | tl(rest)]))
      assert errors == %{"report.records[0]" => ["has an unknown field"]}
    end
  end

  describe "the envelope has a fixed shape" do
    test "missing required fields are errors on their path" do
      for path <- [
            ["workflow_run_id"],
            ["environment"],
            ["source"],
            ["source", "dirty"],
            ["report", "suite_id"],
            ["report", "truncated"],
            ["report", "records"]
          ] do
        assert_error(delete_at(report("complete"), path), Enum.join(path, "."), "is required")
      end
    end

    test "a body project or account_id is an unknown field at any level" do
      complete = report("complete")

      # Reported on the enclosing object: the submitted key name is not echoed.
      assert errors(Map.put(complete, "project", "goodcases")) == %{
               "body" => ["has an unknown field"]
             }

      assert errors(Map.put(complete, "account_id", "x")) == %{
               "body" => ["has an unknown field"]
             }

      assert errors(put_at(complete, ["report", "account_id"], "x")) == %{
               "report" => ["has an unknown field"]
             }

      assert errors(put_at(complete, record_path(2, "account_id"), "x")) == %{
               "report.records[2]" => ["has an unknown field"]
             }

      assert_error(put_at(complete, ["source", "repository"], "x"), "source")
    end

    test "raw failure payloads and logs are rejected without echoing them" do
      sentinel = "SENTINEL-assertion-failed-7f3a"
      complete = report("complete")

      for key <- ["message", "logs", "stacktrace"] do
        errors =
          assert_error(
            put_at(complete, record_path(3, key), sentinel),
            "report.records[3]",
            "has an unknown field"
          )

        refute inspect(errors) =~ sentinel
        refute inspect(errors) =~ key
      end
    end

    test "an unknown key is reported on its object without its name" do
      errors = errors(put_at(report("complete"), ["source", "weird key!"], 1))
      assert errors == %{"source" => ["has an unknown field"]}

      errors = errors(put_at(report("complete"), ["source", "plainkey"], 1))
      assert errors == %{"source" => ["has an unknown field"]}
    end

    test "workflow_run_id must be a lowercase canonical UUID" do
      for bad <- [
            "67F7946D-136B-4608-AB01-E1F251A09754",
            "67f7946d136b4608ab01e1f251a09754",
            "{67f7946d-136b-4608-ab01-e1f251a09754}",
            ""
          ] do
        assert_error(Map.put(report("complete"), "workflow_run_id", bad), "workflow_run_id")
      end
    end

    test "environment is null or 1 to 64 bytes without control characters" do
      complete = report("complete")

      assert {:ok, _, _} = validate(Map.put(complete, "environment", nil))
      assert {:ok, _, _} = validate(Map.put(complete, "environment", String.duplicate("e", 64)))
      # 32 two-byte characters are exactly 64 bytes.
      assert {:ok, _, _} = validate(Map.put(complete, "environment", String.duplicate("é", 32)))

      assert_error(Map.put(complete, "environment", ""), "environment", "can't be blank")

      assert_error(
        Map.put(complete, "environment", String.duplicate("é", 33)),
        "environment",
        "is too long"
      )

      for control <- ["a\nb", "a\tb", "a\u007Fb", "a\u0085b"] do
        assert_error(
          Map.put(complete, "environment", control),
          "environment",
          "must not contain control characters"
        )
      end

      assert_error(Map.put(complete, "environment", 1), "environment", "must be a string")
    end

    test "workflow and job names are bounded" do
      complete = report("complete")

      for key <- ["workflow", "job"] do
        assert {:ok, _, _} = validate(Map.put(complete, key, String.duplicate("j", 64)))
        assert_error(Map.put(complete, key, nil), key, "must be a string")
        assert_error(Map.put(complete, key, String.duplicate("j", 65)), key, "is too long")
        assert_error(Map.put(complete, key, "a\rb"), key)
      end
    end

    test "job_status is a closed vocabulary" do
      for status <- Validator.job_statuses() do
        assert {:ok, _, _} = validate(Map.put(report("failed"), "job_status", status))
      end

      assert_error(
        Map.put(report("complete"), "job_status", "success"),
        "job_status",
        "is invalid"
      )
    end

    test "source accepts only commit, branch and dirty, all nullable" do
      complete = report("complete")
      nulls = %{"commit" => nil, "branch" => nil, "dirty" => nil}

      assert {:ok, _, _} = validate(Map.put(complete, "source", nulls))

      assert {:ok, _, _} =
               validate(put_at(complete, ["source", "commit"], String.duplicate("a", 64)))

      assert {:ok, _, _} =
               validate(put_at(complete, ["source", "commit"], String.duplicate("A", 40)))

      assert {:ok, _, _} =
               validate(
                 put_at(
                   complete,
                   ["source", "commit"],
                   "3F786850e387550FDAB836ed7e6dc881de23001B"
                 )
               )

      for length <- [39, 41, 63, 65] do
        assert_error(
          put_at(complete, ["source", "commit"], String.duplicate("a", length)),
          "source.commit",
          "has invalid format"
        )
      end

      assert_error(put_at(complete, ["source", "commit"], "abc123"), "source.commit")

      assert_error(
        put_at(complete, ["source", "commit"], String.duplicate("g", 40)),
        "source.commit"
      )

      # Publishers send null, not "", when there is no branch.
      assert_error(put_at(complete, ["source", "branch"], ""), "source.branch")

      assert_error(
        put_at(complete, ["source", "branch"], String.duplicate("b", 257)),
        "source.branch",
        "is too long"
      )

      # goodflows `valid_branch` rejects any `char::is_control` (Cc).
      for control <- ["a\u0007b", "a\u007Fb", "a\u0085b", "a\nb"] do
        assert_error(
          put_at(complete, ["source", "branch"], control),
          "source.branch",
          "must not contain control characters"
        )
      end

      assert {:ok, _, _} = validate(put_at(complete, ["source", "branch"], "feat/é-ü"))

      assert_error(
        put_at(complete, ["source", "dirty"], "yes"),
        "source.dirty",
        "must be a boolean"
      )

      assert_error(Map.put(complete, "source", nil), "source", "must be an object")
    end

    test "truncated must be a boolean" do
      assert_error(
        put_at(report("complete"), ["report", "truncated"], "no"),
        "report.truncated",
        "must be a boolean"
      )
    end

    test "suite and report ids follow the identifier rule" do
      for {bad, message} <- [
            {"", "can't be blank"},
            {"-lead", "has invalid format"},
            {"a b", "has invalid format"},
            {"a\n", "has invalid format"},
            {String.duplicate("r", 129), "is too long"}
          ] do
        assert_error(
          put_at(report("complete"), ["report", "report_id"], bad),
          "report.report_id",
          message
        )
      end

      assert {:ok, _, _} = validate(with_report_id(report("complete"), "A1._-z"))
    end

    test "report identity must agree with suite_started" do
      complete = report("complete")

      assert_error(
        put_at(complete, ["report", "partition"], "2"),
        "report.partition",
        "does not match suite_started"
      )

      assert_error(
        put_at(complete, ["report", "partition_count"], 4),
        "report.partition_count",
        "does not match suite_started"
      )

      assert_error(
        put_at(complete, ["report", "suite_id"], "other-suite"),
        rendered(0, "suite_id"),
        "does not match report.suite_id"
      )

      assert_error(
        put_at(complete, ["report", "report_id"], "report-9"),
        rendered(0, "report_id"),
        "does not match report.report_id"
      )
    end

    test "the top level must be an object" do
      assert {:error, {:invalid, %{"body" => ["must be a JSON object"]}}} = validate_json("[]")
      assert {:error, {:invalid, %{"body" => ["must be a JSON object"]}}} = validate_json("1")
    end
  end

  describe "partition fields have a fixed grammar" do
    test "in the envelope and in suite_started" do
      complete = report("complete")

      for {path, rendered} <- [
            {["report"], "report"},
            {["report", "records", 0], "report.records[0]"}
          ] do
        assert_error(put_at(complete, path ++ ["partition"], "a b"), rendered <> ".partition")
        assert_error(put_at(complete, path ++ ["partition"], ""), rendered <> ".partition")
        assert_error(put_at(complete, path ++ ["partition"], 1), rendered <> ".partition")

        assert_error(
          put_at(complete, path ++ ["partition"], String.duplicate("p", 65)),
          rendered <> ".partition",
          "is too long"
        )

        assert_error(
          put_at(complete, path ++ ["partition_count"], 0),
          rendered <> ".partition_count",
          "must be a positive integer"
        )
      end

      unpartitioned =
        complete
        |> put_at(["report", "partition"], nil)
        |> put_at(["report", "partition_count"], nil)
        |> put_at(record_path(0, "partition"), nil)
        |> put_at(record_path(0, "partition_count"), nil)

      assert {:ok, _, "complete"} = validate(unpartitioned)

      tokens =
        complete
        |> put_at(["report", "partition"], "p.1_a-B")
        |> put_at(record_path(0, "partition"), "p.1_a-B")

      assert {:ok, _, "complete"} = validate(tokens)
    end
  end

  describe "every record carries common keys" do
    test "missing common keys are required on every event" do
      complete = report("complete")

      for key <- ["suite_id", "report_id", "received_offset_us"] do
        assert_error(delete_at(complete, record_path(2, key)), rendered(2, key), "is required")
      end

      assert_error(delete_at(complete, record_path(2, "event")), rendered(2, "event"))
    end

    test "record identities must match the envelope" do
      complete = report("complete")

      assert_error(
        put_at(complete, record_path(2, "suite_id"), "other-suite"),
        rendered(2, "suite_id"),
        "does not match report.suite_id"
      )

      assert_error(
        put_at(complete, record_path(2, "report_id"), "report-9"),
        rendered(2, "report_id"),
        "does not match report.report_id"
      )
    end

    test "a record with the retired run_id key is rejected for an unknown key" do
      complete = report("complete")
      record = complete |> records() |> Enum.at(2)
      renamed = record |> Map.delete("suite_id") |> Map.put("run_id", record["suite_id"])

      errors =
        assert_error(
          put_at(complete, ["report", "records", 2], renamed),
          "report.records[2]",
          "has an unknown field"
        )

      assert errors[rendered(2, "suite_id")] == ["is required"]
    end

    test "record ids follow the identifier grammar" do
      assert_error(
        put_at(report("complete"), record_path(2, "suite_id"), "a b"),
        rendered(2, "suite_id"),
        "has invalid format"
      )
    end
  end

  describe "the event vocabulary is closed and ordered" do
    test "events are listed in contract order with their core key sets" do
      assert Validator.events() ==
               ~w(suite_started group_started group_finished test_started test_finished
                  suite_finished interrupted max_failures_reached)

      common = ~w(event meta received_offset_us report_id suite_id)

      expected = %{
        "suite_started" => ~w(filters format partition partition_count runner seed started_at),
        "group_started" => ~w(execution_id file group started_offset_us),
        "group_finished" =>
          ~w(counts duration_us execution_id file group outcome started_offset_us),
        "test_started" => ~w(execution_id file group line name path started_offset_us),
        "test_finished" =>
          ~w(duration_us execution_id file group line name outcome path started_offset_us),
        "suite_finished" => ~w(aborted counts duration_us unfinished_groups unfinished_tests),
        "interrupted" => [],
        "max_failures_reached" => []
      }

      for event <- Validator.events() do
        {:object, fields} = Validator.event_spec(event)
        assert Enum.sort(Map.keys(fields)) == Enum.sort(common ++ expected[event]), event
        assert {:optional, _} = fields["meta"]
      end

      assert Enum.sort(Validator.start_fields("test_finished")) ==
               Enum.sort(expected["test_started"])

      assert Enum.sort(Validator.start_fields("group_finished")) ==
               Enum.sort(expected["group_started"])
    end

    test "unknown and retired events are rejected" do
      complete = report("complete")

      for event <- ["module_started", "module_finished", "test_paused", "log", 1] do
        assert_error(
          put_at(complete, record_path(1, "event"), event),
          rendered(1, "event"),
          "is invalid"
        )
      end
    end

    test "every core key is required, nullable ones included" do
      complete = report("complete")

      for event <- Validator.events() -- ["interrupted", "max_failures_reached"] do
        index = record_index(complete, event)
        {:object, fields} = Validator.event_spec(event)

        for {key, spec} <- fields, key != "event", not match?({:optional, _}, spec) do
          assert_error(delete_at(complete, record_path(index, key)), rendered(index, key))
        end
      end

      finished = record_index(complete, "test_finished")

      assert_error(
        delete_at(complete, record_path(finished, "duration_us")),
        rendered(finished, "duration_us"),
        "is required"
      )
    end

    test "keys outside the core keys, the common keys and meta are rejected" do
      complete = report("complete")

      # A test_started key on a group event.
      assert_error(
        put_at(complete, record_path(1, "line"), 3),
        "report.records[1]",
        "has an unknown field"
      )

      # A finished key on a started event.
      started = record_index(complete, "test_started")

      assert_error(
        put_at(complete, record_path(started, "duration_us"), 1),
        "report.records[#{started}]",
        "has an unknown field"
      )

      interrupted = %{
        "event" => "interrupted",
        "suite_id" => "suite-20261101-a",
        "report_id" => "report-1",
        "received_offset_us" => 1,
        "reason" => "x"
      }

      assert_error(
        with_records(complete, [hd(records(complete)), interrupted]),
        "report.records[1]",
        "has an unknown field"
      )
    end

    test "retired top-level test fields are unknown keys, even when null" do
      complete = report("complete")
      started = record_index(complete, "test_started")

      for key <- ["async", "parameter_id", "describe", "module", "description"],
          value <- [nil, true] do
        assert_error(
          put_at(complete, record_path(started, key), value),
          "report.records[#{started}]",
          "has an unknown field"
        )
      end

      group = record_index(complete, "group_started")

      for key <- ["async", "setup_all", "module"] do
        assert_error(
          put_at(complete, record_path(group, key), nil),
          "report.records[#{group}]",
          "has an unknown field"
        )
      end
    end

    test "retired test fields in meta are accepted" do
      complete = report("complete")
      started = record_index(complete, "test_started")

      assert_accepted(put_meta(complete, started, %{"async" => nil, "parameter_id" => nil}))
    end

    test "suite_started appears once and first; suite_finished once and last" do
      complete = report("complete")
      [first | rest] = records(complete)

      assert_error(
        with_records(complete, tl(records(complete))),
        rendered(0, "event"),
        "must be suite_started"
      )

      assert_error(with_records(complete, [1 | records(complete)]), "report.records[0]")

      assert_error(
        with_records(complete, [first, first | rest]),
        rendered(1, "event"),
        "must only be the first record"
      )

      finished = List.last(rest)
      reordered = [first | List.insert_at(Enum.drop(rest, -1), 3, finished)]

      assert_error(
        with_records(complete, reordered),
        rendered(4, "event"),
        "must be the last record"
      )

      assert_error(
        with_records(complete, records(complete) ++ [finished]),
        rendered(length(rest), "event"),
        "must be the last record"
      )
    end

    test "a record after suite_finished is rejected" do
      complete = report("complete")
      [first | rest] = records(complete)
      started = Enum.find(rest, &(&1["event"] == "test_started"))

      late = %{started | "event" => "test_started", "execution_id" => 99}

      late_finish =
        Map.merge(late, %{"event" => "test_finished", "duration_us" => 1, "outcome" => "passed"})

      document = with_records(complete, [first | rest] ++ [late, late_finish])

      assert_error(document, rendered(length(rest), "event"), "must be the last record")
    end

    test "an interruption without a finish is accepted as incomplete" do
      assert_accepted(report("incomplete"), "incomplete")
      assert List.last(records(report("incomplete")))["event"] == "interrupted"
    end
  end

  describe "suite_started describes the run" do
    test "a Jest run with a negative seed and null filters" do
      suite_started = hd(records(report("failed")))

      assert %{
               "runner" => %{"name" => "jest", "version" => "30.0.0"},
               "seed" => -1843,
               "filters" => nil
             } = suite_started

      assert_accepted(report("failed"))
    end

    test "runner is exactly a name identifier and a nullable short version" do
      complete = report("complete")
      path = record_path(0, "runner")

      for runner <- [
            %{"name" => "exunit", "version" => nil},
            %{"name" => "jest", "version" => String.duplicate("1", 128)},
            %{"name" => "node.test-runner_2", "version" => ""}
          ] do
        assert_accepted(put_at(complete, path, runner))
      end

      assert_error(
        put_at(complete, path, %{"name" => "jest runner", "version" => nil}),
        rendered(0, "runner.name"),
        "has invalid format"
      )

      assert_error(
        put_at(complete, path, %{"name" => "jest", "version" => nil, "url" => "x"}),
        rendered(0, "runner"),
        "has an unknown field"
      )

      assert_error(
        put_at(complete, path, %{"name" => "jest"}),
        rendered(0, "runner.version"),
        "is required"
      )

      assert_error(
        put_at(complete, path, %{"name" => "jest", "version" => String.duplicate("1", 129)}),
        rendered(0, "runner.version"),
        "is too long"
      )

      assert_error(put_at(complete, path, "jest"), rendered(0, "runner"), "must be an object")
    end

    test "seed is null or an integer" do
      complete = report("complete")
      assert_accepted(put_at(complete, record_path(0, "seed"), nil))

      assert_error(
        put_at(complete, record_path(0, "seed"), "1"),
        rendered(0, "seed"),
        "must be an integer"
      )
    end
  end

  describe "started_at uses the contract's UTC timestamp grammar" do
    defp with_started_at(value),
      do: put_at(report("complete"), record_path(0, "started_at"), value)

    test "accepted spellings" do
      for value <- [
            "2026-11-04T12:00:00Z",
            "2026-11-04t12:00:00.123456789z",
            "2026-11-04T12:00:00+00:00",
            "2026-11-04T12:00:00-00:00",
            "2026-12-31T23:59:60Z",
            "2024-02-29T00:00:00Z",
            "0000-02-29T00:00:00Z"
          ] do
        assert {:ok, _, _} = validate(with_started_at(value)), value
      end
    end

    test "rejected spellings" do
      for value <- [
            "2026-11-04 12:00:00Z",
            "2026-11-04T12:00:00+01:00",
            "2026-11-04T12:00:00",
            "2026-02-30T12:00:00Z",
            "2025-02-29T12:00:00Z",
            "2026-13-01T12:00:00Z",
            "2026-00-01T12:00:00Z",
            "2026-11-00T12:00:00Z",
            "2026-11-04T24:00:00Z",
            "2026-11-04T12:60:00Z",
            "2026-11-04T12:00:61Z",
            "2026-11-04T12:00:00.Z",
            "2026-11-04T12:00:00.1",
            "2026-11-04T12:00:00ZZ",
            "2026-11-04T12:00:00Z\n",
            "2026-11-04T12:00:00+0000",
            "2026-11-04T1:00:00Z",
            "+026-11-04T12:00:00Z",
            "2026-11-04",
            "yesterday",
            ""
          ] do
        errors = assert_error(with_started_at(value), rendered(0, "started_at"))
        assert errors[rendered(0, "started_at")] == ["must be a UTC ISO 8601 timestamp"], value
      end

      assert_error(with_started_at(1), rendered(0, "started_at"), "must be a string")
      assert_error(with_started_at(nil), rendered(0, "started_at"), "must be a string")
    end

    test "is at most 64 bytes" do
      at_limit = "2026-11-04T12:00:00." <> String.duplicate("1", 43) <> "Z"
      assert byte_size(at_limit) == 64
      assert {:ok, _, _} = validate(with_started_at(at_limit))

      over = "2026-11-04T12:00:00." <> String.duplicate("1", 44) <> "Z"
      assert byte_size(over) == 65
      assert_error(with_started_at(over), rendered(0, "started_at"), "is too long")
    end
  end

  describe "groups are the runner's scheduling unit" do
    test "a group that failed to load is errored with empty counts" do
      failed = report("failed")

      errored =
        Enum.find(
          records(failed),
          &(&1["event"] == "group_finished" and &1["outcome"] == "errored")
        )

      assert errored["counts"] == %{}
      assert_accepted(failed)
    end

    test "group is text of 1 to 4,096 bytes and file is text or null" do
      complete = report("complete")
      group = record_index(complete, "group_started")

      assert_accepted(put_pair(complete, group, "group", String.duplicate("g", 4096)))
      assert_accepted(put_pair(complete, group, "file", nil))

      assert_error(
        put_pair(complete, group, "group", String.duplicate("g", 4097)),
        rendered(group, "group"),
        "is too long"
      )

      assert_error(
        put_pair(complete, group, "group", ""),
        rendered(group, "group"),
        "can't be blank"
      )

      assert_error(
        put_pair(complete, group, "file", ""),
        rendered(group, "file"),
        "can't be blank"
      )

      assert_error(
        put_pair(complete, group, "file", 1),
        rendered(group, "file"),
        "must be a string"
      )
    end
  end

  describe "tests are identified by group, path and name" do
    test "nested describe blocks and a test outside any describe" do
      complete = report("complete")
      started = record_index(complete, "test_started")

      assert_accepted(put_pair(complete, started, "path", ["math", "sum"]))
      assert_accepted(put_pair(complete, started, "path", []))
    end

    test "path has at most 32 text entries" do
      complete = report("complete")
      started = record_index(complete, "test_started")

      assert_accepted(put_pair(complete, started, "path", List.duplicate("d", 32)))

      errors =
        assert_error(
          put_pair(complete, started, "path", List.duplicate("d", 33)),
          rendered(started, "path"),
          "must not have more than 32 entries"
        )

      assert errors[rendered(started, "path")] == ["must not have more than 32 entries"]

      assert_error(
        put_pair(complete, started, "path", [""]),
        "report.records[#{started}].path[0]",
        "can't be blank"
      )

      assert_error(
        put_pair(complete, started, "path", [String.duplicate("d", 4097)]),
        "report.records[#{started}].path[0]",
        "is too long"
      )

      assert_error(put_pair(complete, started, "path", nil), rendered(started, "path"))
      assert_error(put_pair(complete, started, "path", "math"), rendered(started, "path"))
    end

    test "name is text and line is null or positive" do
      complete = report("complete")
      started = record_index(complete, "test_started")

      assert_error(
        put_pair(complete, started, "name", String.duplicate("n", 4097)),
        rendered(started, "name"),
        "is too long"
      )

      assert_error(put_pair(complete, started, "name", ""), rendered(started, "name"))
      assert_accepted(put_pair(complete, started, "line", nil))

      assert_error(
        put_pair(complete, started, "line", 0),
        rendered(started, "line"),
        "must be a positive integer"
      )
    end
  end

  describe "finished events pair with started events" do
    defp template(event),
      do: report("complete") |> records() |> Enum.find(&(&1["event"] == event))

    test "a group and a test may share an execution id" do
      failed = report("failed")
      assert_accepted(failed)

      complete = report("complete")
      test = record_index(complete, "test_started")
      assert_accepted(put_pair(complete, test, "execution_id", 1))
    end

    test "a finish without a start is rejected" do
      complete = report("complete")
      finish = record_index(complete, "test_finished")

      assert_error(
        put_at(complete, record_path(finish, "execution_id"), 99),
        rendered(finish, "execution_id"),
        "has no matching start event"
      )
    end

    test "a finish of the wrong kind is rejected" do
      document =
        with_records(report("complete"), [
          template("suite_started"),
          Map.put(template("test_started"), "execution_id", 9),
          Map.put(template("group_finished"), "execution_id", 9)
        ])

      assert_error(document, rendered(2, "execution_id"), "has no matching start event")
    end

    test "a finish that changes a core key is rejected" do
      complete = report("complete")
      finish = record_index(complete, "test_finished")

      for {key, value} <- [
            {"name", "other"},
            {"line", 77},
            {"started_offset_us", 1},
            {"path", ["x"]},
            {"group", "Other"},
            {"file", nil}
          ] do
        assert_error(
          put_at(complete, record_path(finish, key), value),
          rendered(finish, "execution_id"),
          "does not match its start event"
        )
      end

      group = record_index(complete, "group_finished")

      for {key, value} <- [
            {"group", "Other"},
            {"file", "test/gc/other_test.exs"},
            {"file", nil},
            {"started_offset_us", 1}
          ] do
        assert_error(
          put_at(complete, record_path(group, key), value),
          rendered(group, "execution_id"),
          "does not match its start event"
        )
      end
    end

    test "a finish may change meta and common keys" do
      complete = report("complete")
      finish = record_index(complete, "test_finished")

      complete
      |> put_meta(finish, %{"retry" => 1})
      |> put_at(record_path(finish, "received_offset_us"), 123_456)
      |> assert_accepted()
    end

    test "finished twice, started again and started twice are rejected" do
      complete = report("complete")
      [first | rest] = records(complete)
      started = template("test_started")
      finished = Enum.find(rest, &(&1["event"] == "test_finished"))

      twice = with_records(complete, [first, started, finished, finished])
      assert_error(twice, rendered(3, "execution_id"), "has no matching start event")

      again = with_records(complete, [first, started, finished, started])
      assert_error(again, rendered(3, "execution_id"), "is already used")

      double = with_records(complete, [first, started, started])
      assert_error(double, rendered(2, "execution_id"), "is already used")

      group = template("group_started")
      double_group = with_records(complete, [first, group, group])
      assert_error(double_group, rendered(2, "execution_id"), "is already used")
    end

    test "a truncated report may end after a test_started" do
      complete = report("complete")

      document =
        complete
        |> with_records([template("suite_started"), template("test_started")])
        |> put_at(["report", "truncated"], true)

      assert_accepted(document, "incomplete")
    end
  end

  describe "outcomes and counts are runner-neutral" do
    test "outcomes are passed, failed, skipped and errored" do
      assert Validator.outcomes() == ~w(passed failed skipped errored)
      complete = report("complete")
      finish = record_index(complete, "test_finished")
      group = record_index(complete, "group_finished")

      for outcome <- Validator.outcomes() do
        assert_accepted(put_at(complete, record_path(finish, "outcome"), outcome))
        assert_accepted(put_at(complete, record_path(group, "outcome"), outcome))
      end

      for outcome <- ["todo", "excluded", "invalid", "pending", nil] do
        assert_error(
          put_at(complete, record_path(finish, "outcome"), outcome),
          rendered(finish, "outcome"),
          "is invalid"
        )
      end
    end

    test "counts keys are a subset of the outcomes with nonnegative values" do
      complete = report("complete")
      index = suite_finished_index(complete)
      path = record_path(index, "counts")

      assert_accepted(put_at(complete, path, %{}))
      assert_accepted(put_at(complete, path, %{"passed" => 1, "errored" => 0}))

      assert_error(
        put_at(complete, path, %{"excluded" => 1}),
        rendered(index, "counts"),
        "has an unknown field"
      )

      assert_error(
        put_at(complete, path, %{"passed" => -1}),
        rendered(index, "counts.passed"),
        "must be a nonnegative integer"
      )

      assert_error(put_at(complete, path, []), rendered(index, "counts"), "must be an object")
    end
  end

  describe "durations and offsets are nonnegative integer microseconds" do
    test "a millisecond runner's converted duration is accepted unchanged" do
      complete = report("complete")
      finish = record_index(complete, "test_finished")
      assert_accepted(put_at(complete, record_path(finish, "duration_us"), 12_000))
    end

    test "negative values are rejected" do
      complete = report("complete")
      finish = record_index(complete, "test_finished")
      group = record_index(complete, "group_finished")
      index = suite_finished_index(complete)

      for {record, key} <- [
            {finish, "duration_us"},
            {group, "duration_us"},
            {index, "duration_us"},
            {1, "received_offset_us"}
          ] do
        assert_error(
          put_at(complete, record_path(record, key), -5),
          rendered(record, key),
          "must be a nonnegative integer"
        )
      end

      started = record_index(complete, "test_started")

      assert_error(
        put_pair(complete, started, "started_offset_us", -1),
        rendered(started, "started_offset_us"),
        "must be a nonnegative integer"
      )

      assert_error(
        put_pair(complete, started, "execution_id", 0),
        rendered(started, "execution_id"),
        "must be a positive integer"
      )
    end

    test "duration_us may be null on every finished event" do
      complete = report("complete")

      for event <- ["test_finished", "group_finished", "suite_finished"] do
        index = record_index(complete, event)
        assert_accepted(put_at(complete, record_path(index, "duration_us"), nil))
      end
    end
  end

  describe "suite_finished summarizes the run" do
    test "unfinished counts must equal the open starts" do
      complete = report("complete")
      index = suite_finished_index(complete)

      assert_error(
        put_at(complete, record_path(index, "unfinished_tests"), 1),
        rendered(index, "unfinished_tests"),
        "does not match the open start events"
      )

      assert_error(
        put_at(complete, record_path(index, "unfinished_groups"), 2),
        rendered(index, "unfinished_groups"),
        "does not match the open start events"
      )

      # One test_started without its test_finished.
      finish = record_index(complete, "test_finished")
      open = with_records(complete, List.delete_at(records(complete), finish))

      assert_error(
        open,
        rendered(index - 1, "unfinished_tests"),
        "does not match the open start events"
      )

      open_group = record_index(complete, "group_finished")
      without_group = List.delete_at(records(complete), open_group)

      fixed =
        without_group
        |> List.update_at(-1, &Map.put(&1, "unfinished_groups", 1))
        |> then(&with_records(complete, &1))

      assert_accepted(fixed, "incomplete")
    end

    test "the retired unfinished_modules counter is rejected" do
      complete = report("complete")
      index = suite_finished_index(complete)
      final = Enum.at(records(complete), index)

      renamed =
        final |> Map.delete("unfinished_groups") |> Map.put("unfinished_modules", 0)

      errors =
        assert_error(
          put_at(complete, ["report", "records", index], renamed),
          "report.records[#{index}]",
          "has an unknown field"
        )

      assert errors[rendered(index, "unfinished_groups")] == ["is required"]
    end

    test "aborted is a boolean" do
      complete = report("complete")
      index = suite_finished_index(complete)

      assert_error(
        put_at(complete, record_path(index, "aborted"), nil),
        rendered(index, "aborted"),
        "must be a boolean"
      )
    end
  end

  describe "runner metadata is flat and bounded" do
    defp meta_errors(meta) do
      document = put_meta(report("complete"), 2, meta)
      assert {:error, {:invalid, errors}} = validate(document)
      errors
    end

    defp keys(count), do: Map.new(1..count, &{"k#{&1}", 1})

    test "flat scalar meta is accepted and stored unchanged on every event" do
      complete = report("complete")

      suite_meta = %{"elixir_version" => "1.20.0", "otp_release" => "28", "max_cases" => 16}
      assert_accepted(put_meta(complete, 0, suite_meta))

      for meta <- [
            %{},
            %{"async" => nil},
            %{"a" => true, "b" => -Document.max_integer(), "c" => Document.max_integer()},
            %{"s" => String.duplicate("s", 256), "e" => ""},
            keys(32),
            %{String.duplicate("k", 128) => 1, "A1._-z" => 2}
          ] do
        for index <- 0..(length(records(complete)) - 1) do
          assert_accepted(put_meta(complete, index, meta))
        end
      end
    end

    test "meta that is not an object" do
      for meta <- [nil, "x", [], 1, true] do
        assert meta_errors(meta) == %{"report.records[2].meta" => ["must be an object"]}
      end
    end

    test "too many meta keys" do
      assert meta_errors(keys(33)) == %{
               "report.records[2].meta" => ["must not have more than 32 keys"]
             }
    end

    test "invalid meta keys are reported on meta without the key" do
      for key <- ["skip reason", "_private", "stack trace", "", "a\n", String.duplicate("k", 129)] do
        errors = meta_errors(%{key => 1})
        assert errors == %{"report.records[2].meta" => ["has an invalid key"]}

        if key != "",
          do: refute(Jason.encode!(errors) =~ key or inspect(errors) =~ inspect(key))
      end
    end

    test "invalid meta values are reported on meta without the key" do
      for value <- [["a", "b"], %{"x" => 1}, 1.5, String.duplicate("s", 257)] do
        errors = meta_errors(%{"secret_key_name" => value})
        assert errors == %{"report.records[2].meta" => ["has an invalid value"]}
        refute Jason.encode!(errors) =~ "secret_key_name"
      end
    end

    test "out-of-range and NUL meta values are reported on meta without the key" do
      max = Document.max_integer()

      for value <- [max + 1, -(max + 1), "a" <> <<0>>, [max + 1], %{"x" => "b" <> <<0>>}] do
        errors = meta_errors(%{"db_password" => value})
        assert errors == %{"report.records[2].meta" => ["has an invalid value"]}
        refute inspect(errors) =~ "db_password"
      end

      # The same through JSON, where Document finds the fault first.
      for token <- ["99999999999999999999", "-9007199254740992", ~s("x\\u0000")] do
        json =
          report("complete")
          |> put_meta(2, %{"db_password" => 900_000_009})
          |> Jason.encode!()
          |> String.replace("900000009", token)

        assert {:error, {:invalid, errors}} = validate_json(json)
        assert errors == %{"report.records[2].meta" => ["has an invalid value"]}
        refute Jason.encode!(errors) =~ "db_password"
      end
    end

    test "a bad key and a bad value are both reported on meta" do
      assert meta_errors(%{"bad key" => [1]}) == %{
               "report.records[2].meta" => ["has an invalid key", "has an invalid value"]
             }
    end

    test "a float meta value from JSON is rejected" do
      json =
        String.replace(
          report_json("complete"),
          ~s("otp_release": "28"),
          ~s("otp_release": 1.5)
        )

      assert {:error, {:invalid, errors}} = validate_json(json)
      assert errors == %{"report.records[0].meta" => ["has an invalid value"]}
    end
  end

  describe "suite filters are boolean identifier tags" do
    defp with_filters(filters), do: put_at(report("complete"), record_path(0, "filters"), filters)

    test "null filters and a tagged run are accepted unchanged" do
      assert_accepted(with_filters(nil))

      assert_accepted(
        with_filters(%{"include" => [%{"tag" => "slow", "value" => true}], "exclude" => []})
      )
    end

    test "repeated and case-sensitive tags keep their order" do
      include = [
        %{"tag" => "Chrome", "value" => true},
        %{"tag" => "chrome", "value" => true},
        %{"tag" => "1x.a-b", "value" => false}
      ]

      exclude = [
        %{"tag" => "chrome", "value" => true},
        %{"tag" => "slow", "value" => true},
        %{"tag" => "slow", "value" => false}
      ]

      accepted = assert_accepted(with_filters(%{"include" => include, "exclude" => exclude}))
      assert hd(records(accepted))["filters"] == %{"include" => include, "exclude" => exclude}

      longest = [%{"tag" => String.duplicate("a", 128), "value" => true}]
      assert_accepted(with_filters(%{"include" => longest, "exclude" => []}))
    end

    test "a missing list or filters key is rejected" do
      assert_error(
        with_filters(%{"include" => []}),
        rendered(0, "filters.exclude"),
        "is required"
      )

      assert_error(
        delete_at(report("complete"), record_path(0, "filters")),
        rendered(0, "filters"),
        "is required"
      )
    end

    test "tags outside the identifier grammar are rejected without echo" do
      path = "report.records[0].filters.include[0].tag"

      for {tag, message} <- [
            {"slow test", "has invalid format"},
            {"ok?", "has invalid format"},
            {"slow\n", "has invalid format"},
            {String.duplicate("a", 129), "is too long"},
            {"", "can't be blank"},
            {1, "must be a string"}
          ] do
        document =
          with_filters(%{"include" => [%{"tag" => tag, "value" => true}], "exclude" => []})

        errors = assert_error(document, path, message)
        assert errors[path] == [message], inspect({tag, errors})

        if is_binary(tag) and tag != "",
          do: refute(inspect(errors) =~ inspect(tag) or Jason.encode!(errors) =~ tag)
      end
    end

    test "filter values are booleans" do
      for value <- ["yes", "on", 1, nil] do
        assert_error(
          with_filters(%{"include" => [], "exclude" => [%{"tag" => "chrome", "value" => value}]}),
          "report.records[0].filters.exclude[0].value",
          "must be a boolean"
        )
      end
    end

    test "each list is capped at 256 entries, reported only on the list" do
      entry = &%{"tag" => &1, "value" => true}

      for list <- ["include", "exclude"], tag <- ["slow", "ok?"] do
        other = if list == "include", do: "exclude", else: "include"
        document = with_filters(%{list => List.duplicate(entry.(tag), 257), other => []})

        assert errors(document) == %{
                 "report.records[0].filters.#{list}" => ["must not have more than 256 entries"]
               }
      end

      entries = Enum.map(1..256, &entry.("t#{&1}"))
      assert_accepted(with_filters(%{"include" => entries, "exclude" => entries}))

      for {list, value} <- [{"include", %{}}, {"exclude", "x"}] do
        other = if list == "include", do: "exclude", else: "include"

        assert errors(with_filters(%{list => value, other => []})) == %{
                 "report.records[0].filters.#{list}" => ["must be an array"]
               }
      end
    end

    test "unknown keys in filters or an entry are rejected without echo" do
      assert_error(
        with_filters(%{"include" => [], "exclude" => [], "x" => 1}),
        rendered(0, "filters"),
        "has an unknown field"
      )

      errors =
        assert_error(
          with_filters(%{
            "include" => [%{"tag" => "slow", "value" => true, "note" => "x"}],
            "exclude" => []
          }),
          "report.records[0].filters.include[0]",
          "has an unknown field"
        )

      refute Jason.encode!(errors) =~ "note"
    end

    test "filters that are not an object are rejected" do
      for filters <- [[], "slow"] do
        assert_error(with_filters(filters), rendered(0, "filters"), "must be an object")
      end
    end
  end

  describe "completion is derived from core fields" do
    test "a report with failed tests and an errored group stays complete" do
      assert {:ok, document, "complete"} = validate(report("failed"))
      assert document["job_status"] == "failed"

      assert Enum.count(
               records(document),
               &(&1["outcome"] == "failed" and &1["event"] == "test_finished")
             ) >= 2

      assert Enum.any?(records(document), &(&1["outcome"] == "errored"))
    end

    test "missing finish, abort, markers, unfinished counts and truncation are incomplete" do
      complete = report("complete")
      last = suite_finished_index(complete)
      [first | rest] = records(complete)

      marker = %{
        "event" => "interrupted",
        "suite_id" => first["suite_id"],
        "report_id" => first["report_id"],
        "received_offset_us" => 5
      }

      max_failures = %{marker | "event" => "max_failures_reached"}

      cases = %{
        "no suite_finished" => with_records(complete, Enum.drop(records(complete), -1)),
        "aborted" => put_at(complete, record_path(last, "aborted"), true),
        "interrupted" => with_records(complete, [first, marker | rest]),
        "max failures, clean finish" => with_records(complete, [first, max_failures | rest]),
        "only ends on interrupted" =>
          with_records(complete, Enum.drop(records(complete), -1) ++ [marker]),
        "truncated" => put_at(complete, ["report", "truncated"], true)
      }

      for {label, document} <- cases do
        assert {:ok, _, "incomplete"} = validate(document), label
      end
    end

    test "a positive unfinished count is incomplete" do
      complete = report("complete")
      last = suite_finished_index(complete)

      for key <- ["unfinished_tests", "unfinished_groups"] do
        document = put_at(complete, record_path(last, key), 1)
        assert Completion.status(document) == "incomplete"
      end

      assert Completion.status(complete) == "complete"
    end

    test "meta does not affect completion" do
      complete = report("complete")
      last = suite_finished_index(complete)

      document = put_meta(complete, last, %{"aborted" => true, "unfinished_tests" => 3})
      assert_accepted(document, "complete")
    end

    test "a truncated prefix of a report is accepted as incomplete" do
      complete = report("complete")

      for size <- 1..(length(records(complete)) - 1) do
        prefix =
          complete
          |> with_records(Enum.take(records(complete), size))
          |> put_at(["report", "truncated"], true)

        assert {:ok, _, "incomplete"} = validate(prefix), "prefix of #{size}"
      end
    end
  end

  describe "documents are bounded and strictly encoded" do
    test "duplicate object keys are rejected" do
      json =
        String.replace(
          report_json("complete"),
          ~s("job": "test",),
          ~s("job": "test", "job": "x",)
        )

      # Reported on the enclosing object, without the key name.
      assert {:error, {:invalid, %{"body" => ["has a duplicate key"]}}} = validate_json(json)

      nested =
        String.replace(
          report_json("complete"),
          ~s("dirty": false),
          ~s("dirty": false, "dirty": true)
        )

      assert {:error, {:invalid, %{"source" => ["has a duplicate key"]}}} =
               validate_json(nested)

      name =
        String.replace(
          report_json("complete"),
          ~s("name": "adds numbers",),
          ~s("name": "adds numbers", "name": "x",),
          global: false
        )

      assert {:error, {:invalid, errors}} = validate_json(name)
      assert [{path, ["has a duplicate key"]}] = Map.to_list(errors)
      assert path =~ ~r/\Areport\.records\[\d+\]\z/
    end

    test "duplicate keys and NULs are reported in document order" do
      json =
        ~s({"job": "a", "job": "b", "workflow": "x\\u0000", "source": {"dirty": 1, "dirty": 2}})

      {:ok, decoded} = Document.decode(json)

      assert Document.normalize(decoded) ==
               {:error,
                [
                  {[], "has a duplicate key"},
                  {["workflow"], "must not contain NUL characters"},
                  {["source"], "has a duplicate key"}
                ]}
    end

    test "strings and keys containing U+0000 are rejected" do
      json = String.replace(report_json("complete"), ~s("job": "test"), ~s("job": "te\\u0000st"))

      assert {:error, {:invalid, %{"job" => ["must not contain NUL characters"]}}} =
               validate_json(json)

      key_json =
        String.replace(
          report_json("complete"),
          ~s("job": "test"),
          ~s("job": "test", "a\\u0000": 1)
        )

      assert {:error, {:invalid, %{"body" => ["must not contain NUL characters"]}}} =
               validate_json(key_json)

      deep = put_at(report("complete"), record_path(2, "name"), "a" <> <<0>>)
      assert_error(deep, rendered(2, "name"), "must not contain NUL characters")
    end

    test "numbers must be integers no larger than 2^53 - 1 in magnitude" do
      max = Document.max_integer()
      complete = report("complete")

      assert {:ok, _, _} = validate(put_at(complete, record_path(0, "seed"), max))
      assert {:ok, _, _} = validate(put_at(complete, record_path(0, "seed"), -max))

      for seed <- [max + 1, -max - 1] do
        assert_error(
          put_at(complete, record_path(0, "seed"), seed),
          rendered(0, "seed"),
          "is out of range"
        )
      end

      finish = record_index(complete, "test_finished")

      json =
        String.replace(
          report_json("complete"),
          ~s("duration_us": 1500,),
          ~s("duration_us": 12.5,)
        )

      assert {:error, {:invalid, errors}} = validate_json(json)
      assert errors[rendered(finish, "duration_us")] == ["must be an integer"]

      exp =
        String.replace(
          report_json("complete"),
          ~s("duration_us": 1500,),
          ~s("duration_us": 1.5e3,)
        )

      assert {:error, {:invalid, _}} = validate_json(exp)
    end

    # goodflows (serde_json) reads `-0` as a float, never an integer.
    test "a -0 number is not an integer" do
      complete =
        report("complete")
        |> put_at(record_path(0, "seed"), 900_000_001)
        |> put_at(record_path(1, "received_offset_us"), 900_000_002)
        |> put_at(record_path(2, "meta"), %{"retries" => 900_000_003})

      json = Jason.encode!(complete)
      negative_zero = fn token -> String.replace(json, Integer.to_string(token), "-0") end

      assert {:error, {:invalid, errors}} = validate_json(negative_zero.(900_000_001))
      assert errors == %{rendered(0, "seed") => ["must be an integer"]}

      assert {:error, {:invalid, errors}} = validate_json(negative_zero.(900_000_002))
      assert errors == %{rendered(1, "received_offset_us") => ["must be an integer"]}

      assert {:error, {:invalid, errors}} = validate_json(negative_zero.(900_000_003))
      assert errors == %{rendered(2, "meta") => ["has an invalid value"]}

      # A positive zero is an integer.
      assert {:ok, _, _} = validate_json(String.replace(json, "900000001", "0"))
    end

    test "only -0 number tokens decode as floats" do
      assert {:ok, [-0.0, -0.0, -0.0, 0]} = Document.decode("[-0, -0 ,-0\n,0]")
      assert {:ok, %Jason.OrderedObject{values: [{"a", -0.0}]}} = Document.decode(~s({"a":-0}))
      assert {:ok, [-0.0, -0.5, 1.0, 1.0, -10]} = Document.decode("[-0.0,-0.5,1e-0,1E+0,-10]")

      # Inside strings `-0` is text, also after escaped quotes and backslashes.
      assert {:ok, ["-0", ~s(a\"-0), "\\", -0.0]} =
               Document.decode(~s(["-0", "a\\\"-0", "\\\\", -0]))

      assert {:error, :malformed_json} = Document.decode("[-01]")

      branch =
        report("complete")
        |> put_at(["source", "branch"], "fix/-0")
        |> put_at(record_path(2, "meta"), %{"note" => "-0"})

      assert {:ok, accepted, _} = validate_json(Jason.encode!(branch))
      assert accepted == branch
    end

    test "records must be a nonempty array of at most 100,000" do
      complete = report("complete")

      assert_error(with_records(complete, []), "report.records", "must not be empty")
      assert_error(with_records(complete, %{}), "report.records", "must be an array")

      incomplete = report("incomplete")
      [first | _] = records(incomplete)
      marker = List.last(records(incomplete))

      at_limit =
        with_records(incomplete, [first | List.duplicate(marker, Validator.max_records() - 1)])

      assert {:ok, _, "incomplete"} = validate(at_limit)

      over = with_records(incomplete, [first | List.duplicate(marker, Validator.max_records())])

      assert {:error,
              {:invalid, %{"report.records" => ["must not have more than 100000 records"]}}} =
               validate(over)
    end

    test "nesting is bounded at 16 levels before decoding" do
      assert Document.max_depth() == 16
      assert Document.check_depth(report_json("complete")) == :ok
      too_deep = String.duplicate("[", 17) <> String.duplicate("]", 17)
      assert Document.check_depth(too_deep) == {:error, :too_deep}
    end
  end

  describe "error rendering" do
    test "the first 50 errors are kept, in document order" do
      document = large_report(130, 0)

      records =
        document |> records() |> Enum.map(&Map.put(&1, "received_offset_us", -1))

      errors = errors(with_records(document, records))

      assert Map.keys(errors) |> Enum.sort() ==
               Enum.sort(for i <- 0..49, do: "report.records[#{i}].received_offset_us")
    end

    test "error bodies use only field paths and fixed messages" do
      sentinel = "SENTINEL-value-91c2"

      document =
        report("complete")
        |> Map.put("job_status", sentinel)
        |> Map.put("workflow", sentinel <> String.duplicate("x", 64))
        |> put_at(record_path(0, "started_at"), sentinel)
        |> put_meta(1, %{sentinel => [sentinel]})

      errors = errors(document)
      refute inspect(errors) =~ sentinel

      allowed_messages = [
        "is invalid",
        "is too long",
        "must be a UTC ISO 8601 timestamp",
        "has an invalid key",
        "has an invalid value"
      ]

      assert errors |> Map.values() |> List.flatten() |> Enum.all?(&(&1 in allowed_messages))
    end

    test "a bad value under an unknown key is reported on the enclosing object" do
      max = Document.max_integer()
      complete = report("complete")
      last = suite_finished_index(complete)

      for {value, message} <- [
            {max + 1, "is out of range"},
            {-(max + 1), "is out of range"},
            {"x" <> <<0>>, "must not contain NUL characters"},
            {%{"inner" => [max + 1]}, "is out of range"}
          ] do
        assert errors(Map.put(complete, "db_password", value)) == %{"body" => [message]}

        record = put_at(complete, record_path(2, "db_password"), value)
        assert errors(record) == %{"report.records[2]" => [message]}

        source = put_at(complete, ["source", "db_password"], value)
        assert errors(source) == %{"source" => [message]}

        counts = put_at(complete, record_path(last, "counts"), %{"db_password" => value})
        assert errors(counts) == %{rendered(last, "counts") => [message]}
      end

      # A contract key on the path is kept.
      assert errors(put_at(complete, record_path(0, "seed"), max + 1)) == %{
               rendered(0, "seed") => ["is out of range"]
             }

      counts = put_at(complete, record_path(last, "counts"), %{"passed" => max + 1})
      assert errors(counts) == %{"report.records[#{last}].counts.passed" => ["is out of range"]}

      filter = record_path(0, "filters") ++ ["include"]

      assert errors(put_at(complete, filter, [%{"tag" => "a" <> <<0>>, "value" => true}])) == %{
               "report.records[0].filters.include[0].tag" => ["must not contain NUL characters"]
             }
    end

    # Every place a submitted key can sit, with every kind of value fault:
    # the key name never reaches an error path or message.
    test "error bodies never contain submitted key names" do
      key = "db_password"
      max = Document.max_integer()
      complete = report("complete")
      last = suite_finished_index(complete)

      locations = [
        [],
        ["source"],
        ["report"],
        record_path(0, "runner"),
        record_path(0, "filters"),
        record_path(2, "meta"),
        record_path(last, "counts"),
        record_path(last, "meta"),
        ["report", "records", 1]
      ]

      values = [
        max + 1,
        -(max + 1),
        "x" <> <<0>>,
        [max + 1],
        %{"nested" => %{key => "y" <> <<0>>}},
        "SENTINEL" <> String.duplicate("s", 300),
        [1.5]
      ]

      for location <- locations, value <- values do
        document =
          case location do
            [] -> Map.put(complete, key, value)
            path -> update_in_path(complete, path, &Map.put(&1, key, value))
          end

        assert {:error, {:invalid, errors}} = validate(document)
        body = Jason.encode!(%{errors: errors})
        refute body =~ key, "#{inspect(location)} #{inspect(value)}: #{body}"
        refute body =~ "nested"
        refute body =~ "SENTINEL"
      end

      # And through JSON with duplicate and NUL-bearing keys.
      json =
        String.replace(
          report_json("complete"),
          ~s("job": "test",),
          ~s("job": "test", "db_password": 1, "db_password": 99999999999999999999, "k\\u0000": 1,)
        )

      assert {:error, {:invalid, errors}} = validate_json(json)
      refute Jason.encode!(errors) =~ key
    end

    test "error bodies are capped" do
      records = report("complete") |> records()

      document =
        with_records(report("complete"), Enum.map(records, &Map.put(&1, "extra", 1)))
        |> Map.merge(Map.new(1..60, &{"extra_#{&1}", 1}))

      assert map_size(errors(document)) <= 50
    end
  end

  describe "large reports" do
    test "large_report/2 builds a valid report close to its byte target" do
      document = large_report(10, 20_000)
      size = document |> Jason.encode!() |> byte_size()

      assert size <= 20_000 and size > 19_900
      assert length(records(document)) == 10
      assert_accepted(document, "complete")
    end
  end

  defp update_in_path(document, [key], fun) when is_integer(key),
    do: List.update_at(document, key, fun)

  defp update_in_path(document, [key], fun), do: Map.update!(document, key, fun)

  defp update_in_path(document, [key | rest], fun) when is_integer(key),
    do: List.update_at(document, key, &update_in_path(&1, rest, fun))

  defp update_in_path(document, [key | rest], fun),
    do: Map.update!(document, key, &update_in_path(&1, rest, fun))

  defp all_keys(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [key | all_keys(value)] end)

  defp all_keys(list) when is_list(list), do: Enum.flat_map(list, &all_keys/1)
  defp all_keys(_value), do: []
end
