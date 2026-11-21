defmodule GoodFlows.WorkflowRuns.ValidatorTest do
  use ExUnit.Case, async: true

  alias GoodFlows.JsonDocument
  alias GoodFlows.WorkflowRuns.Validator

  import GoodFlows.WorkflowRunFixtures, only: [goodflows: 1, goodflows_names: 0]

  @fixtures Path.expand("../../support/fixtures/workflow_runs", __DIR__)
  @golden Path.expand(
            "../../../../openspec/changes/archive/2026-11-09-add-workflow-run-storage/fixtures",
            __DIR__
          )

  @parent_sha "885e038c0f9b987034b408e021199f81da87b707b7f19d97781cc9a1ff79b6dc"
  @child_sha "72e944d953fea14064d52c743e85c247f1bbdcaacbf5a054def8053bab0020b1"

  @messages [
    "can't be blank",
    "is invalid",
    "has an unknown field",
    "has a duplicate key",
    "is too long",
    "must be a boolean",
    "must be a nonnegative integer",
    "must be a positive integer",
    "must be an integer",
    "must be a string",
    "must not contain control characters",
    "has invalid format",
    "must be an array",
    "must be an object",
    "is required",
    "must not be empty",
    "must not contain NUL characters",
    "is out of range",
    "must be a JSON object",
    "must not have more than 1024 entries",
    "must not have more than 32 entries",
    "must be normalized",
    "must be unique",
    "must name a graph job",
    "must not form a cycle"
  ]

  @path ~r/\A(?:body|[A-Za-z_][A-Za-z0-9_]*(?:\[[0-9]+\])?(?:\.[A-Za-z_][A-Za-z0-9_]*(?:\[[0-9]+\])?)*)\z/

  @uuid "fb7d2711-6b67-4f5a-9104-492032a9e1e5"
  @child "0e54fb55-a115-4ac7-80fe-8fde26e76afb"
  @sha String.duplicate("ab", 32)
  @thread "https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"
  @threads "https://ampcode.com/threads/"

  describe "fixtures" do
    test "a workflow run is at most 8 objects or arrays deep" do
      assert Validator.max_depth() == 8
    end

    test "every synthetic fixture and both golden files decode" do
      for name <- ~w(minimal.json full.json cancelled-by-signal.json failed.json) do
        assert {:ok, _decoded} = JsonDocument.decode(File.read!(Path.join(@fixtures, name)))
      end

      assert golden("parent-default.json") |> sha256() == @parent_sha
      assert golden("child-suite.json") |> sha256() == @child_sha

      for name <- ~w(parent-default.json child-suite.json) do
        assert {:ok, _decoded} = JsonDocument.decode(golden(name))
      end
    end

    test "synthetic fixtures and both golden files validate as stored" do
      for name <- ~w(minimal.json full.json cancelled-by-signal.json failed.json) do
        assert {:ok, _document, _columns} = validate_json(File.read!(Path.join(@fixtures, name))),
               name
      end

      assert {:ok, parent, parent_columns} = validate_json(golden("parent-default.json"))
      assert parent["workflow"] == "default"
      assert parent["results"] |> Enum.at(1) |> Map.get("workflow") == "suite"
      assert parent["results"] |> Enum.at(1) |> Map.get("child_run_id") == @child
      assert parent_columns.started_at == ~U[2026-11-09 13:25:31Z]
      assert parent_columns.source_commit == "5a4a9715f1cd0a9795766bcd9294a77549b5b474"
      assert parent_columns.source_dirty == false
      assert parent_columns.environment == nil
      refute Map.has_key?(parent_columns, :parent_run_id)

      assert {:ok, child, child_columns} = validate_json(golden("child-suite.json"))
      assert child["parent_run_id"] == @uuid
      assert child["caller_job"] == "call-suite"
      assert child_columns.workflow == "suite"
      assert child_columns.run_id == @child
      refute Map.has_key?(child_columns, :caller_job)
    end

    test "a full document copies the comparison columns and keeps the payload" do
      assert {:ok, document, columns} =
               validate_json(File.read!(Path.join(@fixtures, "full.json")))

      assert columns.workflow == "ci"
      assert columns.environment == "ci"
      assert columns.outcome == "passed"
      assert columns.duration_ms == 1200
      assert columns.parallelism == 4
      assert columns.max_in_flight == 2
      assert columns.source_dirty == true
      assert columns.host["mem_total_bytes"] == 16_780_623_872
      assert document["requested_jobs"] == ["build", "test"]
      assert document["results"] |> Enum.at(0) |> Map.get("commands") |> length() == 2
    end
  end

  describe "accepted documents" do
    test "a minimal document and a host without memory are accepted" do
      columns = assert_accepted(minimal())
      assert columns.environment == nil
      assert columns.source_commit == nil
      assert columns.source_dirty == nil
      refute Map.has_key?(columns.host, "mem_total_bytes")
    end

    test "environment and requested jobs are stored as given" do
      document = Map.merge(minimal(), %{"environment" => "ci", "requested_jobs" => ["test"]})
      assert_accepted(document)
    end

    test "a name with surrounding spaces is stored without trimming" do
      assert_accepted(Map.put(minimal(), "workflow", "  CI  "))
    end

    test "a workflow call may omit child_run_id and may null the result trio" do
      call =
        result(%{
          "workflow" => "suite",
          "command" => nil,
          "exit_code" => nil,
          "error" => nil
        })

      assert_accepted(put_result(minimal(), call))
    end

    test "null command, exit_code and error are accepted on a call result" do
      call =
        result(%{
          "workflow" => "suite",
          "child_run_id" => @child,
          "command" => nil,
          "exit_code" => nil,
          "error" => nil
        })

      assert_accepted(with_caller(put_result(minimal(), call)))
    end

    test "exit_code accepts the signed 32-bit bounds" do
      assert_accepted(put_result(minimal(), result(%{"exit_code" => -2_147_483_648})))
      assert_accepted(put_result(minimal(), result(%{"exit_code" => 2_147_483_647})))
    end

    test "command text of 1024 bytes and a 64-byte name are accepted" do
      named =
        result(%{"name" => String.duplicate("a", 64), "command" => String.duplicate("x", 1024)})

      assert_accepted(put_result(minimal(), named))
    end

    test "a list of 1024 requested jobs or command costs is accepted" do
      jobs = List.duplicate("build", 1024)
      assert_accepted(Map.put(minimal(), "requested_jobs", jobs))

      commands = List.duplicate(%{"kind" => "command", "wall_ms" => 1}, 1024)
      assert_accepted(put_result(minimal(), result(%{"commands" => commands})))
    end

    test "partition 64 of 64 and a step cost without peak memory are accepted" do
      entry = %{
        "kind" => "command",
        "step" => "compile",
        "wall_ms" => 1,
        "cpu_user_ms" => 0,
        "cpu_system_ms" => 0
      }

      document =
        put_result(
          minimal(),
          result(%{"partition" => %{"index" => 64, "count" => 64}, "commands" => [entry]})
        )

      assert_accepted(document)
    end

    test "a failed outcome with a timed-out result is accepted" do
      assert_accepted(
        put_result(Map.put(minimal(), "outcome", "failed"), result(%{"status" => "timed_out"}))
      )
    end

    test "duration_ms at 2^53-1 is accepted" do
      assert_accepted(Map.put(minimal(), "duration_ms", JsonDocument.max_integer()))
    end
  end

  describe "the body is a run-history document" do
    test "unknown keys, including project and account_id, are rejected on body" do
      for key <- ~w(project account_id) do
        assert_error(Map.put(minimal(), key, "secret_token_xyz"), "body", "has an unknown field")
      end
    end

    test "schema_version 2 is invalid and a non-integer is not an integer" do
      assert_error(Map.put(minimal(), "schema_version", 2), "schema_version", "is invalid")

      assert_error(
        Map.put(minimal(), "schema_version", "1"),
        "schema_version",
        "must be an integer"
      )
    end

    test "a missing required key is required" do
      assert_error(Map.delete(minimal(), "workflow"), "workflow", "is required")
    end

    test "a non-object body is rejected" do
      assert_error([], "body", "must be a JSON object")
    end
  end

  describe "caller and child links" do
    test "parent_run_id without caller_job is invalid on parent_run_id" do
      assert_error(Map.put(minimal(), "parent_run_id", @uuid), "parent_run_id", "is invalid")
    end

    test "caller_job without parent_run_id is invalid on caller_job" do
      assert_error(Map.put(minimal(), "caller_job", "call-suite"), "caller_job", "is invalid")
    end

    test "uppercase parent_run_id and child_run_id are rejected" do
      upper = String.upcase(@uuid)

      assert_error(with_caller(minimal(), upper), "parent_run_id", "has invalid format")

      document = put_result(minimal(), result(%{"workflow" => "suite", "child_run_id" => upper}))
      assert_error(document, "results[0].child_run_id", "has invalid format")
    end

    test "child_run_id without workflow is invalid on child_run_id" do
      document = put_result(minimal(), result(%{"child_run_id" => @child}))
      assert_error(document, "results[0].child_run_id", "is invalid")
    end

    test "null on an omit-only workflow-call key is invalid" do
      assert_error(Map.put(minimal(), "parent_run_id", nil), "parent_run_id", "is invalid")
      assert_error(Map.put(minimal(), "caller_job", nil), "caller_job", "is invalid")

      assert_error(
        put_result(minimal(), result(%{"workflow" => nil})),
        "results[0].workflow",
        "is invalid"
      )

      assert_error(
        put_result(minimal(), result(%{"child_run_id" => nil})),
        "results[0].child_run_id",
        "is invalid"
      )
    end
  end

  describe "run-level fields and names" do
    test "an uppercase run_id is rejected" do
      assert_error(
        Map.put(minimal(), "run_id", String.upcase(@uuid)),
        "run_id",
        "has invalid format"
      )
    end

    test "started_at rejects fractions, offsets and a calendar-invalid day" do
      for value <- [
            "2026-11-05T12:00:00.123Z",
            "2026-11-05T12:00:00+00:00",
            "2026-02-31T12:00:00Z"
          ] do
        assert_error(Map.put(minimal(), "started_at", value), "started_at", "is invalid")
      end
    end

    test "the name rule rejects 65 bytes, whitespace and control characters" do
      long = String.duplicate("n", 65)
      control = "job\u0001"

      assert_error(with_caller(minimal(), @uuid, long), "caller_job", "is too long")
      assert_error(with_caller(minimal(), @uuid, "   "), "caller_job", "can't be blank")

      assert_error(
        with_caller(minimal(), @uuid, control),
        "caller_job",
        "must not contain control characters"
      )

      assert_error(
        put_result(minimal(), result(%{"workflow" => long})),
        "results[0].workflow",
        "is too long"
      )

      assert_error(
        put_result(minimal(), result(%{"workflow" => "   "})),
        "results[0].workflow",
        "can't be blank"
      )

      assert_error(
        put_result(minimal(), result(%{"workflow" => control})),
        "results[0].workflow",
        "must not contain control characters"
      )

      assert_error(Map.put(minimal(), "workflow", "   "), "workflow", "can't be blank")

      assert_error(
        put_result(minimal(), result(%{"name" => long})),
        "results[0].name",
        "is too long"
      )

      assert_error(
        put_result(
          minimal(),
          result(%{"commands" => [%{"kind" => "command", "step" => long, "wall_ms" => 1}]})
        ),
        "results[0].commands[0].step",
        "is too long"
      )
    end

    test "source.commit rejects the wrong length and uppercase hex" do
      assert_error(
        put_source(String.duplicate("ab", 20) <> "c"),
        "source.commit",
        "has invalid format"
      )

      assert_error(put_source(String.duplicate("a", 39)), "source.commit", "has invalid format")
      assert_error(put_source(String.duplicate("A", 40)), "source.commit", "has invalid format")
    end

    test "empty requested_jobs and a 1025-entry list are rejected" do
      assert_error(
        Map.put(minimal(), "requested_jobs", []),
        "requested_jobs",
        "must not be empty"
      )

      assert_error(
        Map.put(minimal(), "requested_jobs", List.duplicate("build", 1025)),
        "requested_jobs",
        "must not have more than 1024 entries"
      )
    end
  end

  describe "results, partitions and command costs" do
    test "stdout on a result is an unknown field on that result" do
      assert_error(
        put_result(minimal(), result(%{"stdout" => "secret_token_xyz"})),
        "results[0]",
        "has an unknown field"
      )
    end

    test "a 1025-byte command or error is too long" do
      text = String.duplicate("x", 1025)

      assert_error(
        put_result(minimal(), result(%{"command" => text})),
        "results[0].command",
        "is too long"
      )

      assert_error(
        put_result(minimal(), result(%{"error" => text})),
        "results[0].error",
        "is too long"
      )
    end

    test "omitting command, exit_code or error is a missing required key" do
      for key <- ~w(command exit_code error) do
        assert_error(
          put_result(minimal(), Map.delete(result(), key)),
          "results[0].#{key}",
          "is required"
        )
      end
    end

    test "exit_code outside the signed 32-bit range is invalid" do
      assert_error(
        put_result(minimal(), result(%{"exit_code" => 2_147_483_648})),
        "results[0].exit_code",
        "is invalid"
      )

      assert_error(
        put_result(minimal(), result(%{"exit_code" => -2_147_483_649})),
        "results[0].exit_code",
        "is invalid"
      )
    end

    test "partition bounds reject count 65, index 0 and an index past count" do
      assert_error(partition(1, 65), "results[0].partition", "is invalid")
      assert_error(partition(0, 2), "results[0].partition.index", "must be a positive integer")
      assert_error(partition(4, 3), "results[0].partition", "is invalid")
    end

    test "peak_rss_bytes of 0 is rejected and an empty or oversized commands list is rejected" do
      assert_error(
        commands([%{"kind" => "command", "wall_ms" => 1, "peak_rss_bytes" => 0}]),
        "results[0].commands[0].peak_rss_bytes",
        "must be a positive integer"
      )

      assert_error(commands([]), "results[0].commands", "must not be empty")

      assert_error(
        commands(List.duplicate(%{"kind" => "command", "wall_ms" => 1}, 1025)),
        "results[0].commands",
        "must not have more than 1024 entries"
      )
    end

    test "the JSON number 1.0 is not an integer and an integer above 2^53-1 is out of range" do
      assert_error(json_number(~s("duration_ms":1.0)), "duration_ms", "must be an integer")

      assert_error(
        json_number(~s("duration_ms":9007199254740992)),
        "duration_ms",
        "is out of range"
      )
    end
  end

  describe "outcome agrees with result statuses" do
    test "passed with a failure, failed with none, and passed with a cancellation are rejected" do
      assert_error(outcome("passed", "failed"), "outcome", "is invalid")
      assert_error(outcome("failed", "passed"), "outcome", "is invalid")
      assert_error(outcome("passed", "cancelled"), "outcome", "is invalid")
    end

    test "cancelled with a failure and passed with a timeout are rejected" do
      assert_error(outcome("cancelled", "failed"), "outcome", "is invalid")
      assert_error(outcome("passed", "timed_out"), "outcome", "is invalid")
    end

    test "cancelled with every result passed is the signal snapshot and is accepted" do
      assert_accepted(outcome("cancelled", "passed"))
    end
  end

  describe "error shape" do
    test "a duplicate key is reported on the enclosing object and does not echo the value" do
      decoded = decode!(~s({"outcome":"passed","outcome":"SENTINEL_DUP_9f3a"}))
      errors = errors(decoded)
      assert errors["body"] == ["has a duplicate key"]
      refute sentinel?(errors, "SENTINEL_DUP_9f3a")
    end

    test "NUL and an unknown key's sentinel never appear in the error" do
      nul = decode!(~s({"workflow":"ab\\u0000SENTINEL_NUL_9f3a"}))
      errors = errors(nul)
      assert errors["workflow"] == ["must not contain NUL characters"]
      refute sentinel?(errors, "SENTINEL_NUL_9f3a")

      unknown = decode!(~s({"secret_token_xyz":"SENTINEL_UNKNOWN_9f3a\\u0000"}))
      errors = errors(unknown)
      assert errors["body"] == ["must not contain NUL characters"]
      refute sentinel?(errors, "secret_token_xyz")
      refute sentinel?(errors, "SENTINEL_UNKNOWN_9f3a")
    end

    test "an unknown key is not echoed" do
      errors = errors(Map.put(minimal(), "secret_token_xyz", "top-secret"))
      assert errors["body"] == ["has an unknown field"]
      refute sentinel?(errors, "secret_token_xyz")
      refute sentinel?(errors, "top-secret")
    end

    test "a sentinel in command is not echoed" do
      document =
        minimal()
        |> Map.put("outcome", "green")
        |> put_result(result(%{"command" => "SENTINEL_COMMAND_9f3a"}))

      refute sentinel?(errors(document), "SENTINEL_COMMAND_9f3a")

      oversized =
        put_result(
          minimal(),
          result(%{"command" => String.duplicate("x", 1025) <> "SENTINEL_COMMAND_9f3a"})
        )

      refute sentinel?(errors(oversized), "SENTINEL_COMMAND_9f3a")
    end

    test "only the first 50 errors in document order are returned" do
      results = List.duplicate(result(%{"status" => "nope"}), 51)
      errors = errors(Map.put(minimal(), "results", results))

      assert map_size(errors) == 50
      assert errors["results[0].status"] == ["is invalid"]
      assert errors["results[49].status"] == ["is invalid"]
      refute Map.has_key?(errors, "results[50].status")
    end

    test "a child pairing error keeps its place ahead of later result errors" do
      orphan = result(%{"child_run_id" => @child})
      broken = result(%{"status" => "nope"})
      errors = errors(Map.put(minimal(), "results", [orphan | List.duplicate(broken, 50)]))

      assert MapSet.new(Map.keys(errors)) ==
               MapSet.new(["results[0].child_run_id" | Enum.map(1..49, &"results[#{&1}].status")])
    end

    test "a caller pairing error keeps its place ahead of later result errors" do
      broken = List.duplicate(result(%{"status" => "nope"}), 50)

      errors =
        minimal()
        |> Map.put("parent_run_id", @uuid)
        |> Map.put("results", broken)
        |> errors()

      assert MapSet.new(Map.keys(errors)) ==
               MapSet.new(["parent_run_id" | Enum.map(0..48, &"results[#{&1}].status")])
    end

    test "a few thousand orphan results stay within the first 50 errors" do
      broken = result(%{"status" => "nope", "child_run_id" => @child})
      errors = errors(Map.put(minimal(), "results", List.duplicate(broken, 4_000)))

      expected =
        Enum.flat_map(0..24, fn index ->
          ["results[#{index}].child_run_id", "results[#{index}].status"]
        end)

      assert map_size(errors) == 50
      assert MapSet.new(Map.keys(errors)) == MapSet.new(expected)
    end

    test "an outcome error keeps its place ahead of later result errors" do
      broken = result(%{"status" => "failed", "command" => String.duplicate("x", 1_025)})

      errors =
        minimal()
        |> Map.put("outcome", "passed")
        |> Map.put("results", List.duplicate(broken, 50))
        |> errors()

      assert MapSet.new(Map.keys(errors)) ==
               MapSet.new(["outcome" | Enum.map(0..48, &"results[#{&1}].command")])
    end
  end

  describe "the upload envelope" do
    test "every vendored goodflows fixture validates and copies branch and ci" do
      for name <- goodflows_names() do
        assert {:ok, _document, _columns} = Validator.validate(goodflows(name)), name
      end

      columns = assert_accepted(goodflows("full"))
      assert columns.source_branch == "feature/login"
      assert columns.ci["event"] == "pull_request"

      columns = assert_accepted(goodflows("history-parent-default"))
      assert columns.source_branch == nil
      assert columns.ci == nil
    end

    test "optional envelope keys may be absent but never null" do
      for path <- [["ci"], ["graph"], ["source", "branch"], ["ci", "event"], ["ci", "url"]] do
        assert_error(put_in(full(), path, nil), Enum.join(path, "."), "is invalid")
      end

      assert_error(put_job(full(), 2, ["call"], nil), "graph.jobs[2].call", "is invalid")

      for key <- ~w(event run_id attempt pull_request runner url) do
        assert_accepted(update_in(full(), ["ci"], &Map.delete(&1, key)))
      end

      assert_accepted(Map.put(full(), "ci", %{"provider" => "github_actions"}))
      assert_accepted(update_in(full(), ["source"], &Map.delete(&1, "branch")))
    end

    test "nullable graph keys must be present and may be null" do
      for key <- ~w(command partitions timeout_secs condition) do
        assert_error(drop_job_key(full(), 0, key), "graph.jobs[0].#{key}", "is required")
        assert_accepted(put_job(full(), 0, [key], nil))
      end

      for key <- ~w(shell condition) do
        document =
          update_in(full(), ["graph", "jobs", at(1), "steps", at(0)], &Map.delete(&1, key))

        assert_error(document, "graph.jobs[1].steps[0].#{key}", "is required")
      end

      for key <- ~w(name depends_on shell steps) do
        assert_error(drop_job_key(full(), 0, key), "graph.jobs[0].#{key}", "is required")
        assert_error(put_job(full(), 0, [key], nil), "graph.jobs[0].#{key}", nil)
      end
    end

    test "source.branch is 1 to 256 bytes without control characters" do
      assert_accepted(put_in(full(), ["source", "branch"], String.duplicate("b", 256)))
      assert_accepted(put_in(full(), ["source", "branch"], "   "))

      for {branch, message} <- [
            {String.duplicate("b", 257), "is too long"},
            {"a\nb", "must not contain control characters"},
            {"", "can't be blank"},
            {7, "must be a string"}
          ] do
        assert_error(put_in(full(), ["source", "branch"], branch), "source.branch", message)
      end
    end

    test "ci follows the D3 rules" do
      assert_error(
        update_in(full(), ["ci"], &Map.delete(&1, "provider")),
        "ci.provider",
        "is required"
      )

      for {key, value, message} <- [
            {"provider", "gitlab", "is invalid"},
            {"event", String.duplicate("e", 65), "is too long"},
            {"event", "  ", "can't be blank"},
            {"runner", "a\tb", "must not contain control characters"},
            {"run_id", String.duplicate("1", 257), "is too long"},
            {"attempt", 0, "must be a positive integer"},
            {"pull_request", "42", "must be an integer"},
            {"url", "http://ghe.local/a/b/actions/runs/1", "is invalid"},
            {"url", "https:///a/b", "is invalid"},
            {"url", "github.com/a/b", "is invalid"},
            {"url", "https://github.com/" <> String.duplicate("a", 2030), "is too long"}
          ] do
        assert_error(put_in(full(), ["ci", key], value), "ci.#{key}", message)
      end

      assert_accepted(put_in(full(), ["ci", "run_id"], String.duplicate("1", 256)))

      assert_accepted(
        put_in(full(), ["ci", "url"], "https://ghe.example:8443/a/b/actions/runs/1")
      )

      assert_error(put_in(full(), ["ci", "token"], "x"), "ci", "has an unknown field")
    end

    test "graph jobs number 1 to 1,024, and depends_on and steps at most 1,024" do
      job = full()["graph"]["jobs"] |> hd() |> Map.put("condition", nil)
      jobs = fn n -> for i <- 1..n//1, do: Map.put(job, "name", "j#{i}") end

      assert_error(
        Map.put(full(), "graph", %{"jobs" => []}),
        "graph.jobs",
        "must not be empty"
      )

      assert_error(
        Map.put(minimal(), "graph", %{"jobs" => jobs.(1025)}),
        "graph.jobs",
        "must not have more than 1024 entries"
      )

      assert_accepted(Map.put(minimal(), "graph", %{"jobs" => jobs.(1024)}))

      assert_error(
        put_job(full(), 1, ["depends_on"], List.duplicate("build", 1025)),
        "graph.jobs[1].depends_on",
        "must not have more than 1024 entries"
      )

      step = full()["graph"]["jobs"] |> Enum.at(1) |> Map.fetch!("steps") |> Enum.at(1)

      assert_error(
        put_job(full(), 1, ["steps"], List.duplicate(step, 1025)),
        "graph.jobs[1].steps",
        "must not have more than 1024 entries"
      )

      assert_error(
        Map.put(full(), "graph", %{"jobs" => [], "x" => 1}),
        "graph",
        "has an unknown field"
      )
    end

    test "graph text is at most 1,024 bytes and partition counts at most 64" do
      for {path, rendered} <- [
            {["graph", "jobs", at(0), "command"], "graph.jobs[0].command"},
            {["graph", "jobs", at(0), "condition", "text"], "graph.jobs[0].condition.text"},
            {["graph", "jobs", at(1), "steps", at(0), "command"],
             "graph.jobs[1].steps[0].command"},
            {["graph", "jobs", at(1), "steps", at(0), "condition", "text"],
             "graph.jobs[1].steps[0].condition.text"}
          ] do
        assert_error(put_in(full(), path, String.duplicate("x", 1025)), rendered, "is too long")
        assert_accepted(put_in(full(), path, String.duplicate("é", 512)))
      end

      assert_error(
        put_job(full(), 1, ["partitions", "count"], 65),
        "graph.jobs[1].partitions.count",
        "is invalid"
      )

      assert_error(
        put_job(full(), 1, ["partitions", "count"], 0),
        "graph.jobs[1].partitions.count",
        "must be a positive integer"
      )

      assert_accepted(put_job(full(), 1, ["partitions", "count"], 64))

      assert_error(
        put_job(full(), 1, ["partitions", "strategy"], "hash"),
        "graph.jobs[1].partitions.strategy",
        "is invalid"
      )

      assert_error(
        put_job(full(), 0, ["condition", "kind"], "regex"),
        "graph.jobs[0].condition.kind",
        "is invalid"
      )

      assert_error(
        put_job(full(), 0, ["timeout_secs"], 0),
        "graph.jobs[0].timeout_secs",
        "must be a positive integer"
      )

      assert_error(put_job(full(), 0, ["env"], %{}), "graph.jobs[0]", "has an unknown field")
    end

    test "job names are unique and dependencies are known and acyclic" do
      assert_error(put_job(full(), 2, ["name"], "build"), "graph.jobs[2].name", "must be unique")

      assert_error(
        put_job(full(), 1, ["depends_on"], ["deploy"]),
        "graph.jobs[1].depends_on[0]",
        "must name a graph job"
      )

      # build -> test -> build: reported on the job that closes the cycle.
      assert_error(
        put_job(full(), 0, ["depends_on"], ["test"]),
        "graph.jobs[1].depends_on",
        "must not form a cycle"
      )

      assert_error(
        put_job(full(), 0, ["depends_on"], ["build"]),
        "graph.jobs[0].depends_on",
        "must not form a cycle"
      )

      # build -> integration -> test -> build: the search from build closes it at test.
      errors =
        assert_error(
          put_job(full(), 0, ["depends_on"], ["integration"]),
          "graph.jobs[1].depends_on",
          "must not form a cycle"
        )

      assert map_size(errors) == 1
    end

    test "every result names a graph job, and without a graph results are not cross-checked" do
      document = put_in(full(), ["results", at(0), "name"], "deploy")
      assert_error(document, "results[0].name", "must name a graph job")
      assert_accepted(Map.delete(document, "graph"))
    end

    test "a called workflow is referenced by graph_sha256 and never inlined" do
      call = ["call"]

      assert_error(
        put_job(full(), 2, call ++ ["graph_sha256"], String.duplicate("AB", 32)),
        "graph.jobs[2].call.graph_sha256",
        "has invalid format"
      )

      assert_error(
        put_job(full(), 2, call ++ ["graph_sha256"], "ab"),
        "graph.jobs[2].call.graph_sha256",
        "has invalid format"
      )

      assert_error(
        update_in(full(), ["graph", "jobs", at(2), "call"], &Map.delete(&1, "workflow")),
        "graph.jobs[2].call.workflow",
        "is required"
      )

      inlined = put_job(full(), 2, call ++ ["jobs"], full()["graph"]["jobs"])
      assert_error(inlined, "graph.jobs[2].call", "has an unknown field")
    end

    test "envelope errors never echo a submitted value" do
      document =
        full()
        |> put_in(["ci", "url"], "http://SENTINEL_URL_7a1")
        |> put_job(0, ["SENTINEL_KEY_7a1"], "x")
        |> put_job(1, ["depends_on"], ["SENTINEL_DEP_7a1"])

      errors = errors(document)
      refute sentinel?(errors, "SENTINEL")
    end
  end

  describe "links" do
    test "threads only, tickets only, or both are accepted and copied into columns" do
      columns = assert_accepted(links(%{"threads" => [@thread]}))
      assert columns.link_threads == [@thread]
      assert columns.link_tickets == []

      columns = assert_accepted(links(%{"tickets" => ["GOO-291", "Abc!~"]}))
      assert columns.link_tickets == ["goo-291", "abc!~"]
      assert columns.link_threads == []

      both = %{"threads" => [@thread, @threads <> "T-2"], "tickets" => ["GOO-291"]}
      columns = assert_accepted(Map.put(full(), "links", both))
      assert columns.link_threads == both["threads"]
      assert columns.link_tickets == ["goo-291"]

      columns = assert_accepted(minimal())
      assert columns.link_tickets == []
      assert columns.link_threads == []
    end

    test "links is a nonempty object of nonnull lists with no other key" do
      errors = assert_error(links(%{}), "links", "must not be empty")
      assert map_size(errors) == 1

      assert_error(Map.put(minimal(), "links", nil), "links", "is invalid")
      assert_error(Map.put(minimal(), "links", []), "links", "must be an object")

      errors =
        assert_error(
          links(%{"threads" => nil, "tickets" => ["GOO-291"]}),
          "links.threads",
          "is invalid"
        )

      assert map_size(errors) == 1

      assert_error(links(%{"tickets" => nil}), "links.tickets", "is invalid")
      assert_error(links(%{"tickets" => []}), "links.tickets", "must not be empty")
      assert_error(links(%{"threads" => []}), "links.threads", "must not be empty")
      assert_error(links(%{"tickets" => "GOO-1"}), "links.tickets", "must be an array")

      errors =
        assert_error(
          links(%{"tickets" => ["GOO-1"], "prs" => [1]}),
          "links",
          "has an unknown field"
        )

      refute sentinel?(errors, "prs")

      assert errors(links(%{"prs" => [1]})) == %{
               "links" => ["has an unknown field", "must not be empty"]
             }
    end

    test "each list holds 1 to 32 entries" do
      threads = for i <- 1..33, do: @threads <> "T-#{i}"
      tickets = for i <- 1..33, do: "GOO-#{i}"

      assert_accepted(
        links(%{"threads" => Enum.take(threads, 32), "tickets" => Enum.take(tickets, 32)})
      )

      for {key, list} <- [{"threads", threads}, {"tickets", tickets}] do
        errors =
          assert_error(
            links(%{key => list}),
            "links.#{key}",
            "must not have more than 32 entries"
          )

        assert map_size(errors) == 1
      end
    end

    test "a ticket is 1 to 64 bytes of printable ASCII other than a comma" do
      assert_accepted(links(%{"tickets" => [String.duplicate("T", 64)]}))
      assert_accepted(links(%{"tickets" => ["!\"#$%&'()*+-./09:;<=>?@AZ[\\]^_`az{|}~"]}))

      for {ticket, message} <- [
            {String.duplicate("T", 65), "is too long"},
            {"", "can't be blank"},
            {"GOO 1", "has invalid format"},
            {"GOO\t1", "has invalid format"},
            {"GOO-1,GOO-2", "has invalid format"},
            {"GOÖ-1", "has invalid format"},
            {7, "must be a string"}
          ] do
        assert_error(links(%{"tickets" => [ticket]}), "links.tickets[0]", message)
      end
    end

    test "repeats are not unique on their own path: tickets ignoring ASCII case, threads exactly" do
      errors =
        assert_error(
          links(%{"tickets" => ["GOO-1", "GOO-2", "goo-1"]}),
          "links.tickets[2]",
          "must be unique"
        )

      assert map_size(errors) == 1

      errors =
        assert_error(
          links(%{"threads" => [@thread, @thread]}),
          "links.threads[1]",
          "must be unique"
        )

      assert map_size(errors) == 1

      # Percent triplets are compared as written, so these are two threads.
      assert_accepted(links(%{"threads" => [@threads <> "a%7Eb", @threads <> "a%7eb"]}))

      # A structural error is not reported again as a repeat.
      assert errors(links(%{"tickets" => ["GOO 1", "goo 1"]})) == %{
               "links.tickets[0]" => ["has invalid format"],
               "links.tickets[1]" => ["has invalid format"]
             }

      assert errors(links(%{"tickets" => List.duplicate("GOO-1", 33)})) == %{
               "links.tickets" => ["must not have more than 32 entries"]
             }

      assert errors(links(%{"threads" => [@thread <> "?x", @thread <> "?x"]})) == %{
               "links.threads[0]" => ["is invalid"],
               "links.threads[1]" => ["is invalid"]
             }
    end

    test "thread URLs already in normalized form are accepted as written" do
      for url <- [
            @thread,
            "https://ampcode.com/",
            "https://ampcode.com:8443/threads/T-1",
            "https://ampcode.com:80/threads/T-1",
            "https://ampcode.com:65535/threads/T-1",
            @threads <> "a%7Eb",
            @threads <> "a%7eb",
            @threads <> "a%2fb",
            @threads <> "a:b@c!$&'()*+,;=-._~",
            @threads <> "a.b/..c/.d",
            "https://127.0.0.1/threads/T-1",
            "https://[::1]/threads/T-1",
            "https://[1:0:0:1::1]/threads/T-1",
            long_url(2048)
          ] do
        columns = assert_accepted(links(%{"threads" => [url]}))
        assert columns.link_threads == [url], url
      end
    end

    test "a thread URL is an https URL with a host and only pchar in its path" do
      for url <- [
            @threads <> "T-1?",
            @threads <> "T-1#",
            @threads <> "T-1?token=secret",
            @threads <> "T-1#frag",
            "http://ampcode.com/threads/T-1",
            "HTTPS://ampcode.com/threads/T-1",
            "https://user:pw@ampcode.com/threads/T-1",
            "https://@ampcode.com/threads/T-1",
            "https:///threads/T-1",
            "https://ampcode.com:65536/threads/T-1",
            "ampcode.com/threads/T-1",
            @threads <> "T-1[x]",
            @threads <> "T-1]",
            @threads <> "T|1",
            @threads <> "T^1",
            @threads <> "T-1%zz",
            @threads <> "T-1%z",
            @threads <> "T-1%"
          ] do
        assert_error(links(%{"threads" => [url]}), "links.threads[0]", "is invalid")
      end

      assert_error(links(%{"threads" => [long_url(2049)]}), "links.threads[0]", "is too long")
      assert_error(links(%{"threads" => [7]}), "links.threads[0]", "must be a string")
    end

    test "a thread URL not in reqwest::Url form must be normalized" do
      for url <- [
            "https://AmpCode.com/threads/T-1",
            "https://ampcode.com:443/threads/T-1",
            "https://ampcode.com:0443/threads/T-1",
            "https://ampcode.com:/threads/T-1",
            "https://ampcode.com:080/threads/T-1",
            "https://ampcode.com",
            "https://ampcode.com/a/../threads/T-1",
            "https://ampcode.com/a/./threads/T-1",
            "https://ampcode.com/threads/T-1/.",
            "https://ampcode.com/a/%2E%2e/threads/T-1",
            "https://ampcode.com/a/%2e/threads/T-1",
            "https://ampcode.com/a/.%2e/threads/T-1",
            "https://ampcode.com/a/%2e./threads/T-1",
            "https://ex%61mple.com/threads/T-1",
            "https://127.1/threads/T-1",
            "https://0x7f.1/threads/T-1",
            "https://0x7f.0.0.1/threads/T-1",
            "https://127.0.0.1./threads/T-1",
            "https://127.000.0.1/threads/T-1",
            "https://[0:0:0:0:0:0:0:1]/threads/T-1",
            "https://[::FFFF:1.2.3.4]/threads/T-1",
            "https://[::1]:443/threads/T-1"
          ] do
        errors =
          assert_error(links(%{"threads" => [url]}), "links.threads[0]", "must be normalized")

        assert errors == %{"links.threads[0]" => ["must be normalized"]}, url
      end
    end

    test "link errors never echo a submitted value" do
      document =
        links(%{
          "threads" => [
            @threads <> "T-1?token=SENTINEL_TOKEN_9c4",
            "https://SENTINEL-HOST.com/a",
            "http://SENTINEL-http/a",
            "https://h/SENTINEL" <> String.duplicate("s", 2048)
          ],
          "tickets" => ["SENTINEL TICKET", String.duplicate("SENTINEL", 9)],
          "SENTINEL_KEY_9c4" => []
        })

      errors = errors(document)
      assert map_size(errors) == 7
      refute sentinel?(errors, "SENTINEL")

      duplicates =
        links(%{
          "threads" => [@threads <> "SENTINEL", @threads <> "SENTINEL"],
          "tickets" => ["SENTINEL-1", "sentinel-1"]
        })

      errors = errors(duplicates)
      assert Map.keys(errors) |> Enum.sort() == ["links.threads[1]", "links.tickets[1]"]
      refute errors |> inspect() |> String.downcase() |> String.contains?("sentinel")
    end
  end

  defp links(links), do: Map.put(minimal(), "links", links)

  defp long_url(bytes), do: @threads <> String.duplicate("a", bytes - byte_size(@threads))

  defp full, do: goodflows("full")

  defp at(index), do: Access.at(index)

  defp put_job(document, index, path, value),
    do: put_in(document, ["graph", "jobs", at(index) | path], value)

  defp drop_job_key(document, index, key),
    do: update_in(document, ["graph", "jobs", at(index)], &Map.delete(&1, key))

  defp minimal(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "workflow" => "ci",
        "run_id" => "11111111-1111-4111-8111-111111111111",
        "started_at" => "2026-11-05T12:00:00Z",
        "outcome" => "passed",
        "duration_ms" => 0,
        "parallelism" => 1,
        "graph_sha256" => @sha,
        "max_in_flight" => 0,
        "host" => %{"os" => "linux", "arch" => "x86_64", "logical_cpus" => 1},
        "results" => []
      },
      overrides
    )
  end

  defp result(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "test",
        "status" => "passed",
        "exit_code" => 0,
        "command" => "mix test",
        "error" => nil,
        "duration_ms" => 1,
        "started" => true,
        "blocked_ms" => 0,
        "queued_ms" => 0
      },
      overrides
    )
  end

  defp put_result(document, entry), do: Map.put(document, "results", [entry])

  defp with_caller(document, parent \\ @uuid, caller \\ "call-suite") do
    Map.merge(document, %{"parent_run_id" => parent, "caller_job" => caller})
  end

  defp put_source(commit), do: Map.put(minimal(), "source", %{"commit" => commit})

  defp partition(index, count) do
    put_result(minimal(), result(%{"partition" => %{"index" => index, "count" => count}}))
  end

  defp commands(entries), do: put_result(minimal(), result(%{"commands" => entries}))

  defp outcome(outcome, status) do
    minimal()
    |> Map.put("outcome", outcome)
    |> put_result(result(%{"status" => status}))
  end

  defp json_number(replacement) do
    minimal()
    |> Jason.encode!()
    |> String.replace(~s("duration_ms":0), replacement)
    |> decode!()
  end

  defp golden(name), do: File.read!(Path.join(@golden, name))

  defp sha256(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp decode!(json) do
    {:ok, decoded} = JsonDocument.decode(json)
    decoded
  end

  defp validate_json(json) do
    json |> decode!() |> Validator.validate()
  end

  defp assert_accepted(document) do
    assert {:ok, accepted, columns} = Validator.validate(document)
    assert {:ok, normalized} = JsonDocument.normalize(document)
    assert accepted == normalized
    columns
  end

  defp assert_error(document, path, message) do
    errors = errors(document)
    assert Map.has_key?(errors, path), "expected an error on #{path}, got #{inspect(errors)}"
    if message, do: assert(message in errors[path], inspect(errors))
    errors
  end

  defp errors(document) do
    assert {:error, {:invalid, errors}} = Validator.validate(document)

    for {path, messages} <- errors, message <- messages do
      assert path =~ @path, "unexpected path #{inspect(path)}"
      assert message in @messages, "unexpected message #{inspect(message)}"
    end

    errors
  end

  defp sentinel?(errors, sentinel) do
    errors
    |> inspect()
    |> String.contains?(sentinel)
  end
end
