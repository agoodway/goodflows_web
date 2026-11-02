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

  defp record_index(document, event) do
    Enum.find_index(records(document), &(&1["event"] == event))
  end

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

    test "fixtures together use every event kind and nested file totals" do
      events = names() |> Enum.flat_map(&records(report(&1))) |> Enum.map(& &1["event"])
      assert Enum.sort(Enum.uniq(events)) == Enum.sort(Validator.events())

      finished = "complete" |> report() |> records() |> List.last()
      assert [%{"async" => %{}, "sync" => %{}, "unknown" => %{}} | _] = finished["files"]
    end

    test "the OpenAPI request example is a valid report" do
      example = TestReportRequest.schema().example
      assert {:ok, _document, "complete"} = validate(example)
    end
  end

  describe "envelope fields" do
    test "missing required fields are errors on their path" do
      for path <- [
            ["format"],
            ["workflow_run_id"],
            ["environment"],
            ["source"],
            ["source", "dirty"],
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

      assert errors(put_at(complete, ["report", "records", 2, "account_id"], "x")) == %{
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
            put_at(complete, ["report", "records", 3, key], sentinel),
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
        assert_error(Map.put(complete, key, nil), key, "must be a string")
        assert_error(Map.put(complete, key, String.duplicate("j", 65)), key, "is too long")
        assert_error(Map.put(complete, key, "a\rb"), key)
      end
    end

    test "job_status and format are closed vocabularies" do
      for status <- Validator.job_statuses() do
        assert {:ok, _, _} = validate(Map.put(report("failed"), "job_status", status))
      end

      assert_error(
        Map.put(report("complete"), "job_status", "success"),
        "job_status",
        "is invalid"
      )

      assert_error(Map.put(report("complete"), "format", "junit"), "format", "is invalid")
    end

    test "source accepts only commit, branch and dirty, all nullable" do
      complete = report("complete")
      nulls = %{"commit" => nil, "branch" => nil, "dirty" => nil}

      assert {:ok, _, _} = validate(Map.put(complete, "source", nulls))

      assert {:ok, _, _} =
               validate(put_at(complete, ["source", "commit"], String.duplicate("a", 64)))

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

      assert_error(
        put_at(complete, ["source", "dirty"], "yes"),
        "source.dirty",
        "must be a boolean"
      )

      assert_error(Map.put(complete, "source", nil), "source", "must be an object")
    end

    test "suite and report ids follow the identifier rule" do
      for {bad, message} <- [
            {"", "can't be blank"},
            {"-lead", "has invalid format"},
            {"a b", "has invalid format"},
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

    test "partition is null or a 1 to 64 byte token and must match suite_started" do
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

      assert_error(put_at(complete, ["report", "partition"], ""), "report.partition")
      assert_error(put_at(complete, ["report", "partition"], 1), "report.partition")
      assert_error(put_at(complete, ["report", "partition_count"], 0), "report.partition_count")

      unpartitioned =
        complete
        |> put_at(["report", "partition"], nil)
        |> put_at(["report", "partition_count"], nil)
        |> put_at(["report", "records", 0, "partition"], nil)
        |> put_at(["report", "records", 0, "partition_count"], nil)

      assert {:ok, _, "complete"} = validate(unpartitioned)
    end

    test "the top level must be an object" do
      assert {:error, {:invalid, %{"body" => ["must be a JSON object"]}}} = validate_json("[]")
      assert {:error, {:invalid, %{"body" => ["must be a JSON object"]}}} = validate_json("1")
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
  end

  describe "JSON-level rules" do
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

      deep = put_at(report("complete"), ["report", "records", 2, "name"], "a" <> <<0>>)
      assert_error(deep, "report.records[2].name", "must not contain NUL characters")
    end

    test "numbers must be integers no larger than 2^53 - 1" do
      max = Document.max_integer()
      complete = report("complete")

      assert {:ok, _, _} = validate(put_at(complete, ["report", "records", 0, "seed"], max))
      assert {:ok, _, _} = validate(put_at(complete, ["report", "records", 0, "seed"], -max))

      assert_error(
        put_at(complete, ["report", "records", 0, "seed"], max + 1),
        "report.records[0].seed",
        "is out of range"
      )

      json =
        String.replace(
          report_json("complete"),
          ~s("received_offset_us": 120,),
          ~s("received_offset_us": 120.0,)
        )

      assert {:error, {:invalid, errors}} = validate_json(json)
      assert errors["report.records[1].received_offset_us"] == ["must be an integer"]

      exp =
        String.replace(
          report_json("complete"),
          ~s("received_offset_us": 120,),
          ~s("received_offset_us": 1.2e2,)
        )

      assert {:error, {:invalid, _}} = validate_json(exp)

      assert_error(
        put_at(complete, ["report", "records", 1, "received_offset_us"], -1),
        "report.records[1].received_offset_us",
        "must be a nonnegative integer"
      )
    end
  end

  describe "records" do
    test "must be a nonempty array starting with suite_started" do
      complete = report("complete")

      assert_error(with_records(complete, []), "report.records", "must not be empty")
      assert_error(with_records(complete, %{}), "report.records", "must be an array")

      assert_error(
        with_records(complete, tl(records(complete))),
        "report.records[0].event",
        "must be suite_started"
      )

      assert_error(with_records(complete, [1 | records(complete)]), "report.records[0]")
    end

    test "suite_started appears once and suite_finished only last" do
      complete = report("complete")
      [first | rest] = records(complete)

      assert_error(
        with_records(complete, [first, first | rest]),
        "report.records[1].event",
        "must only be the first record"
      )

      finished = List.last(rest)
      reordered = [first | List.insert_at(Enum.drop(rest, -1), 3, finished)]

      assert_error(
        with_records(complete, reordered),
        "report.records[4].event",
        "must be the last record"
      )
    end

    test "unknown events and event-specific unknown fields are rejected" do
      complete = report("complete")

      assert_error(
        put_at(complete, ["report", "records", 1, "event"], "test_paused"),
        "report.records[1].event",
        "is invalid"
      )

      # A test_started field on a module event.
      assert_error(
        put_at(complete, ["report", "records", 1, "line"], 3),
        "report.records[1]",
        "has an unknown field"
      )

      interrupted = %{
        "event" => "interrupted",
        "run_id" => "suite-20261101-a",
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

    test "record identities must match the envelope" do
      complete = report("complete")

      assert_error(
        put_at(complete, ["report", "records", 2, "run_id"], "other-suite"),
        "report.records[2].run_id",
        "does not match report.suite_id"
      )

      assert_error(
        put_at(complete, ["report", "records", 2, "report_id"], "report-9"),
        "report.records[2].report_id",
        "does not match report.report_id"
      )
    end

    test "100,000 records are accepted and 100,001 rejected on report.records" do
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
  end

  describe "event fields" do
    test "files must be relative without parent traversal" do
      complete = report("complete")

      for bad <- [
            "/abs/test.exs",
            "\\\\share\\x.exs",
            "C:/x.exs",
            "~/x.exs",
            "test/../x.exs",
            "..",
            ""
          ] do
        assert_error(
          put_at(complete, ["report", "records", 2, "file"], bad),
          "report.records[2].file"
        )
      end

      assert_error(
        put_at(complete, ["report", "records", 2, "file"], String.duplicate("a", 4097)),
        "report.records[2].file",
        "is too long"
      )
    end

    test "text fields are bounded at 4,096 bytes" do
      complete = report("complete")

      for key <- ["module", "name", "description", "describe"] do
        assert_error(
          put_at(complete, ["report", "records", 2, key], String.duplicate("x", 4097)),
          "report.records[2].#{key}",
          "is too long"
        )
      end

      assert_error(
        put_at(complete, ["report", "records", 0, "elixir_version"], String.duplicate("1", 129)),
        "report.records[0].elixir_version",
        "is too long"
      )
    end

    test "suite filters accept boolean identifier tags in supplied order" do
      complete = report("complete")
      include = [%{"tag" => "slow", "value" => true}]

      exclude = [
        %{"tag" => "chrome", "value" => true},
        %{"tag" => "slow", "value" => true},
        %{"tag" => "slow", "value" => false}
      ]

      document =
        complete
        |> put_at(["report", "records", 0, "filters"], %{
          "include" => include,
          "exclude" => exclude
        })

      assert {:ok, accepted, "complete"} = validate(document)
      assert hd(records(accepted))["filters"] == %{"include" => include, "exclude" => exclude}

      cased = [
        %{"tag" => "Chrome", "value" => true},
        %{"tag" => "chrome", "value" => true},
        %{"tag" => "1x.a-b", "value" => false}
      ]

      assert {:ok, accepted, "complete"} =
               validate(put_at(complete, ["report", "records", 0, "filters", "include"], cased))

      assert hd(records(accepted))["filters"]["include"] == cased

      longest = [%{"tag" => String.duplicate("a", 128), "value" => true}]

      assert {:ok, accepted, "complete"} =
               validate(put_at(complete, ["report", "records", 0, "filters", "include"], longest))

      assert hd(records(accepted))["filters"]["include"] == longest
    end

    test "suite filter tags outside the identifier grammar are rejected without echo" do
      complete = report("complete")
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
          put_at(complete, ["report", "records", 0, "filters", "include"], [
            %{"tag" => tag, "value" => true}
          ])

        errors = assert_error(document, path, message)
        assert errors[path] == [message], inspect({tag, errors})

        if is_binary(tag) and tag != "",
          do: refute(inspect(errors) =~ inspect(tag) or Jason.encode!(errors) =~ tag)
      end
    end

    test "suite filter values and entries keep their shape" do
      complete = report("complete")

      assert_error(
        put_at(complete, ["report", "records", 0, "filters", "exclude"], [
          %{"tag" => "qpdf", "value" => "on"}
        ]),
        "report.records[0].filters.exclude[0].value",
        "must be a boolean"
      )

      errors =
        assert_error(
          put_at(complete, ["report", "records", 0, "filters", "include"], [
            %{"tag" => "slow", "value" => true, "note" => "x"}
          ]),
          "report.records[0].filters.include[0]",
          "has an unknown field"
        )

      refute Jason.encode!(errors) =~ "note"
    end

    test "per-test tags are rejected on test events" do
      complete = report("complete")

      for event <- ["test_started", "test_finished"] do
        index = record_index(complete, event)

        assert_error(
          put_at(complete, ["report", "records", index, "tags"], ["slow"]),
          "report.records[#{index}]",
          "has an unknown field"
        )
      end
    end

    test "suite filter lists are capped at 256 entries" do
      complete = report("complete")
      path = ["report", "records", 0, "filters", "include"]
      entry = &%{"tag" => &1, "value" => true}

      for tag <- ["slow", "ok?"] do
        assert {:error, {:invalid, errors}} =
                 validate(put_at(complete, path, List.duplicate(entry.(tag), 257)))

        assert errors == %{
                 "report.records[0].filters.include" => ["must not have more than 256 entries"]
               }
      end

      assert {:error, {:invalid, errors}} =
               validate(
                 put_at(
                   complete,
                   ["report", "records", 0, "filters", "exclude"],
                   List.duplicate(entry.("slow"), 257)
                 )
               )

      assert errors == %{
               "report.records[0].filters.exclude" => ["must not have more than 256 entries"]
             }

      entries = Enum.map(1..256, &entry.("t#{&1}"))
      assert {:ok, _document, "complete"} = validate(put_at(complete, path, entries))

      assert {:ok, _document, "complete"} =
               validate(put_at(complete, ["report", "records", 0, "filters", "exclude"], entries))

      for {list, value} <- [{"include", %{}}, {"exclude", "x"}] do
        assert {:error, {:invalid, errors}} =
                 validate(put_at(complete, ["report", "records", 0, "filters", list], value))

        assert errors == %{"report.records[0].filters.#{list}" => ["must be an array"]}
      end
    end

    test "suite_started fields are checked" do
      complete = report("complete")

      assert_error(
        put_at(complete, ["report", "records", 0, "started_at"], "2026-11-01T12:00:00+02:00"),
        "report.records[0].started_at"
      )

      assert_error(
        put_at(complete, ["report", "records", 0, "started_at"], "yesterday"),
        "report.records[0].started_at"
      )

      assert_error(
        put_at(complete, ["report", "records", 0, "max_cases"], 0),
        "report.records[0].max_cases",
        "must be a positive integer"
      )

      assert_error(
        put_at(complete, ["report", "records", 0, "filters", "only"], []),
        "report.records[0].filters",
        "has an unknown field"
      )
    end

    test "nullable skipped and invalid metadata is accepted without fabricated cost" do
      complete = report("complete")
      skipped = Enum.find_index(records(complete), &(&1["outcome"] == "skipped"))
      skipped_record = Enum.at(records(complete), skipped)
      assert skipped_record["duration_us"] == nil

      # A skipped test with unknown async and parameter identity.
      {:ok, document, "complete"} = validate(report("complete"))
      assert Enum.at(records(document), skipped)["duration_us"] == nil

      excluded = "complete" |> report() |> records() |> Enum.find(&(&1["outcome"] == "excluded"))
      assert %{"async" => nil, "parameter_id" => nil, "file" => nil, "line" => nil} = excluded
    end

    test "duration_us is an integer exactly for passed and failed tests" do
      complete = report("complete")
      passed = Enum.find_index(records(complete), &(&1["outcome"] == "passed"))
      skipped = Enum.find_index(records(complete), &(&1["outcome"] == "skipped"))

      assert_error(
        put_at(complete, ["report", "records", passed, "duration_us"], nil),
        "report.records[#{passed}].duration_us",
        "is required for passed and failed tests"
      )

      assert_error(
        put_at(complete, ["report", "records", skipped, "duration_us"], 5),
        "report.records[#{skipped}].duration_us"
      )
    end

    test "a duration longer than the receipt interval is accepted unchanged" do
      complete = report("complete")

      index =
        Enum.find_index(
          records(complete),
          &(&1["event"] == "test_finished" and &1["file"] == "test/gc/beta_test.exs")
        )

      record = Enum.at(records(complete), index)
      long = record["received_offset_us"] - record["started_offset_us"] + 1_000_000
      extra = long - record["duration_us"]

      last = length(records(complete)) - 1
      files = Enum.at(records(complete), last)["files"]
      file = Enum.find_index(files, &(&1["file"] == "test/gc/beta_test.exs"))
      summary = ["report", "records", last, "files", file]
      file_entry = Enum.at(files, file)

      document =
        complete
        |> put_at(["report", "records", index, "duration_us"], long)
        |> put_at(summary ++ ["test_duration_us"], file_entry["test_duration_us"] + extra)
        |> put_at(
          summary ++ ["sync", "test_duration_us"],
          file_entry["sync"]["test_duration_us"] + extra
        )

      assert {:ok, stored, "complete"} = validate(document)
      assert Enum.at(records(stored), index)["duration_us"] == long
    end
  end

  describe "execution pairing" do
    test "a finish must match an open start with identical start fields" do
      complete = report("complete")
      finish = record_index(complete, "test_finished")

      assert_error(
        put_at(complete, ["report", "records", finish, "execution_id"], 99),
        "report.records[#{finish}].execution_id",
        "has no matching start event"
      )

      assert_error(
        put_at(complete, ["report", "records", finish, "line"], 77),
        "report.records[#{finish}].execution_id",
        "does not match its start event"
      )

      assert_error(
        put_at(complete, ["report", "records", finish, "started_offset_us"], 1),
        "report.records[#{finish}].execution_id",
        "does not match its start event"
      )
    end

    test "execution ids are unique across tests and modules" do
      complete = report("complete")
      start = record_index(complete, "test_started")

      assert_error(
        put_at(complete, ["report", "records", start, "execution_id"], 1),
        "report.records[#{start}].execution_id",
        "is already used"
      )
    end

    test "a module finish cannot close a test start" do
      complete = report("complete")
      finish = record_index(complete, "module_finished")

      assert_error(
        put_at(complete, ["report", "records", finish, "execution_id"], 2),
        "report.records[#{finish}].execution_id"
      )
    end

    test "unmatched starts are allowed in an incomplete report" do
      assert {:ok, _, "incomplete"} = validate(report("incomplete"))
    end
  end

  describe "suite_finished summary" do
    setup do
      complete = report("complete")
      index = length(records(complete)) - 1
      %{complete: complete, index: index, path: ["report", "records", index]}
    end

    test "counts must equal the finished test outcomes", ctx do
      assert_error(
        put_at(ctx.complete, ctx.path ++ ["counts", "passed"], 3),
        "report.records[#{ctx.index}].counts",
        "does not match the finished events"
      )

      # Zero entries are equivalent to omitted ones.
      assert {:ok, _, _} = validate(put_at(ctx.complete, ctx.path ++ ["counts", "invalid"], 0))

      assert_error(
        put_at(ctx.complete, ctx.path ++ ["counts", "flaky"], 0),
        "report.records[#{ctx.index}].counts",
        "has an unknown field"
      )
    end

    test "unfinished counters must equal the open starts", ctx do
      assert_error(
        put_at(ctx.complete, ctx.path ++ ["unfinished_tests"], 1),
        "report.records[#{ctx.index}].unfinished_tests"
      )

      assert_error(
        put_at(ctx.complete, ctx.path ++ ["unfinished_modules"], 2),
        "report.records[#{ctx.index}].unfinished_modules"
      )
    end

    test "file totals and buckets must agree with the finished events", ctx do
      files = Enum.at(records(ctx.complete), ctx.index)["files"]

      for change <- [
            ["test_count"],
            ["test_duration_us"],
            ["observed_module_duration_us"],
            ["module_count"],
            ["async", "test_count"],
            ["sync", "test_duration_us"],
            ["unknown", "module_count"]
          ] do
        changed = put_at(ctx.complete, ctx.path ++ ["files", 0] ++ change, 12_345)
        assert_error(changed, "report.records[#{ctx.index}].files")
      end

      assert_error(
        put_at(ctx.complete, ctx.path ++ ["files"], files ++ [hd(files)]),
        "report.records[#{ctx.index}].files"
      )

      assert_error(
        put_at(ctx.complete, ctx.path ++ ["files"], tl(files)),
        "report.records[#{ctx.index}].files"
      )

      assert {:ok, _, _} =
               validate(put_at(ctx.complete, ctx.path ++ ["files"], Enum.reverse(files)))

      assert_error(
        put_at(ctx.complete, ctx.path ++ ["files", 0, "async", "file"], "x"),
        "report.records[#{ctx.index}].files[0].async",
        "has an unknown field"
      )
    end

    test "times_us sync and total follow run, async and load", ctx do
      assert_error(
        put_at(ctx.complete, ctx.path ++ ["times_us", "sync"], 1),
        "report.records[#{ctx.index}].times_us.sync",
        "must equal run minus async"
      )

      assert_error(
        put_at(ctx.complete, ctx.path ++ ["times_us", "total"], 1),
        "report.records[#{ctx.index}].times_us.total",
        "must equal run plus load"
      )

      nulls =
        ctx.complete
        |> put_at(ctx.path ++ ["times_us"], %{
          "run" => 10,
          "async" => nil,
          "sync" => 10,
          "load" => nil,
          "total" => 10
        })

      assert {:ok, _, _} = validate(nulls)
    end
  end

  describe "completion" do
    test "a complete report with failures stays complete" do
      assert {:ok, document, "complete"} = validate(report("failed"))
      assert document["job_status"] == "failed"
      assert Enum.any?(records(document), &(&1["outcome"] == "failed"))
    end

    test "missing finish marker, abort, markers, unfinished counts and truncation are incomplete" do
      complete = report("complete")
      last = length(records(complete)) - 1
      [first | rest] = records(complete)

      marker = %{
        "event" => "interrupted",
        "run_id" => first["run_id"],
        "report_id" => first["report_id"],
        "received_offset_us" => 5
      }

      max_failures = %{marker | "event" => "max_failures_reached"}

      cases = %{
        "no suite_finished" => with_records(complete, Enum.drop(records(complete), -1)),
        "aborted" => put_at(complete, ["report", "records", last, "aborted"], true),
        "interrupted" => with_records(complete, [first, marker | rest]),
        "max failures, clean finish" => with_records(complete, [first, max_failures | rest]),
        "truncated" => put_at(complete, ["report", "truncated"], true)
      }

      for {label, document} <- cases do
        assert {:ok, _, "incomplete"} = validate(document), label
      end
    end

    test "a positive unfinished count is incomplete" do
      document = put_at(report("complete"), ["report", "records", 13, "unfinished_tests"], 1)
      assert Completion.status(document) == "incomplete"
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

  describe "error bodies" do
    test "use only field paths and fixed messages" do
      sentinel = "SENTINEL-value-91c2"

      document =
        report("complete")
        |> Map.put("job_status", sentinel)
        |> Map.put("workflow", sentinel <> String.duplicate("x", 64))
        |> put_at(["report", "records", 0, "started_at"], sentinel)

      errors = errors(document)
      refute inspect(errors) =~ sentinel

      allowed_messages = [
        "is invalid",
        "is too long",
        "must be a UTC ISO 8601 timestamp"
      ]

      assert errors |> Map.values() |> List.flatten() |> Enum.all?(&(&1 in allowed_messages))
    end

    test "are capped" do
      records = report("complete") |> records()

      document =
        with_records(report("complete"), Enum.map(records, &Map.put(&1, "extra", 1)))
        |> Map.merge(Map.new(1..60, &{"extra_#{&1}", 1}))

      assert map_size(errors(document)) <= 50
    end
  end

  defp all_keys(map) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> [key | all_keys(value)] end)

  defp all_keys(list) when is_list(list), do: Enum.flat_map(list, &all_keys/1)
  defp all_keys(_value), do: []
end
