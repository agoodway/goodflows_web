defmodule GoodFlowsWeb.Schemas.TestReportRequest do
  @moduledoc """
  OpenAPI schema for a test report upload body. There is no `project` or
  `account_id` property: the project is the path slug and the account comes
  from the API key.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.{TestReportEvent, TestReportParts}

  # Property names are the wire keys as strings (generated from the
  # validator's specs), which the `OpenApiSpex.Schema` typespec (atom keys)
  # does not describe; the schema itself is valid OpenAPI.
  @dialyzer {:nowarn_function, schema: 0}

  @common %{"suite_id" => "suite-123", "report_id" => "report-1"}

  @group %{
    "group" => "MathTest",
    "file" => "test/math_test.exs",
    "execution_id" => 1,
    "started_offset_us" => 100
  }

  @test %{
    "group" => "MathTest",
    "path" => ["sum"],
    "name" => "adds",
    "file" => "test/math_test.exs",
    "line" => 4,
    "execution_id" => 1,
    "started_offset_us" => 150
  }

  @example %{
    "format" => "test-timings/1",
    "workflow_run_id" => "67f7946d-136b-4608-ab01-e1f251a09754",
    "workflow" => "default",
    "environment" => "local",
    "job" => "test",
    "job_status" => "passed",
    "source" => %{"commit" => nil, "branch" => nil, "dirty" => nil},
    "report" => %{
      "suite_id" => "suite-123",
      "report_id" => "report-1",
      "partition" => "1",
      "partition_count" => 3,
      "truncated" => false,
      "records" => [
        Map.merge(@common, %{
          "event" => "suite_started",
          "received_offset_us" => 0,
          "format" => "test-timings/1",
          "started_at" => "2026-11-01T12:00:00.000000Z",
          "runner" => %{"name" => "exunit", "version" => "1.19.1"},
          "partition" => "1",
          "partition_count" => 3,
          "seed" => 412_893,
          "filters" => nil,
          "meta" => %{"otp_release" => "28", "max_cases" => 16}
        }),
        @common
        |> Map.merge(@group)
        |> Map.merge(%{"event" => "group_started", "received_offset_us" => 100}),
        @common
        |> Map.merge(@test)
        |> Map.merge(%{"event" => "test_started", "received_offset_us" => 150}),
        @common
        |> Map.merge(@test)
        |> Map.merge(%{
          "event" => "test_finished",
          "received_offset_us" => 700,
          "duration_us" => 520,
          "outcome" => "passed"
        }),
        @common
        |> Map.merge(@group)
        |> Map.merge(%{
          "event" => "group_finished",
          "received_offset_us" => 800,
          "duration_us" => 690,
          "outcome" => "passed",
          "counts" => %{"passed" => 1}
        }),
        Map.merge(@common, %{
          "event" => "suite_finished",
          "received_offset_us" => 1_200,
          "aborted" => false,
          "unfinished_tests" => 0,
          "unfinished_groups" => 0,
          "counts" => %{"passed" => 1},
          "duration_us" => 1_200
        })
      ]
    }
  }

  OpenApiSpex.schema(
    TestReportParts.envelope(TestReportEvent)
    |> Map.from_struct()
    |> Map.merge(%{
      title: "TestReportRequest",
      description:
        "One `test-timings/1` report, as produced by goodflows. Every key shown " <>
          "is required except a record's optional `meta`; unknown keys, duplicate " <>
          "keys, strings containing U+0000 and objects/arrays nested more than 16 " <>
          "levels deep are rejected with `422` (an unknown or duplicate key, or an " <>
          "invalid `meta` key, is reported on its enclosing object, without the key " <>
          "name).",
      example: @example
    }),
    struct?: false
  )
end
