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

  @common %{"run_id" => "suite-123", "report_id" => "report-1"}

  @example %{
    "format" => "exunit-timings",
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
          "format" => "exunit-timings",
          "started_at" => "2026-11-01T12:00:00.000000Z",
          "partition" => "1",
          "partition_count" => 3,
          "seed" => 412_893,
          "max_cases" => 16,
          "schedulers" => 8,
          "elixir_version" => "1.19.1",
          "otp_release" => "28",
          "filters" => %{"include" => [], "exclude" => []}
        }),
        Map.merge(@common, %{
          "event" => "suite_finished",
          "received_offset_us" => 1_200,
          "aborted" => false,
          "unfinished_tests" => 0,
          "unfinished_modules" => 0,
          "counts" => %{},
          "files" => [],
          "times_us" => %{
            "run" => 900,
            "async" => nil,
            "sync" => 900,
            "load" => 300,
            "total" => 1_200
          }
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
        "One `exunit-timings` report. Every key shown is required; unknown keys, " <>
          "duplicate keys, strings containing U+0000 and objects/arrays nested more " <>
          "than 16 levels deep are rejected with `422` (an unknown or duplicate key " <>
          "is reported on its enclosing object, without the key name).",
      example: @example
    }),
    struct?: false
  )
end
