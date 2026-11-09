defmodule GoodFlows.WorkflowRuns.ValidatorTest do
  use ExUnit.Case, async: true

  alias GoodFlows.JsonDocument
  alias GoodFlows.WorkflowRuns.Validator

  @fixtures Path.expand("../../support/fixtures/workflow_runs", __DIR__)
  @golden Path.expand("../../../../openspec/changes/add-workflow-run-storage/fixtures", __DIR__)

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
    "must not have more than 1024 entries"
  ]

  @path ~r/\A(?:body|[A-Za-z_][A-Za-z0-9_]*(?:\[[0-9]+\])?(?:\.[A-Za-z_][A-Za-z0-9_]*(?:\[[0-9]+\])?)*)\z/

  @uuid "fb7d2711-6b67-4f5a-9104-492032a9e1e5"
  @child "0e54fb55-a115-4ac7-80fe-8fde26e76afb"
  @sha String.duplicate("ab", 32)

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
    test "unknown keys, including project, account_id, graph and ci, are rejected on body" do
      for key <- ~w(project account_id graph ci) do
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

    test "source.commit rejects the wrong length and uppercase hex, and branch is unknown" do
      assert_error(
        put_source(String.duplicate("ab", 20) <> "c"),
        "source.commit",
        "has invalid format"
      )

      assert_error(put_source(String.duplicate("a", 39)), "source.commit", "has invalid format")
      assert_error(put_source(String.duplicate("A", 40)), "source.commit", "has invalid format")

      document = put_source(String.duplicate("a", 40))
      document = put_in(document, ["source", "branch"], "main")
      assert_error(document, "source", "has an unknown field")
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
    assert message in errors[path], inspect(errors)
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
