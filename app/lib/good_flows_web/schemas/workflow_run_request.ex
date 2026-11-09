defmodule GoodFlowsWeb.Schemas.WorkflowRunRequest do
  @moduledoc """
  OpenAPI schema for a workflow-run upload body. There is no `project` or
  `account_id` property: the project is the path slug and the account comes
  from the API key. Optional keys are absent or a value, never null. The
  required result keys `command`, `exit_code` and `error` are the only
  nullable keys.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.WorkflowRunParts

  # Property names are the wire keys as strings (generated from the
  # validator's specs), which the `OpenApiSpex.Schema` typespec (atom keys)
  # does not describe; the schema itself is valid OpenAPI.
  @dialyzer {:nowarn_function, schema: 0}

  OpenApiSpex.schema(
    WorkflowRunParts.document()
    |> Map.from_struct()
    |> Map.merge(%{
      title: "WorkflowRunRequest",
      description: """
      One goodflows run-history document at `schema_version` 1. Required keys
      must be present. Optional keys (`environment`, `requested_jobs`,
      `source`, `parent_run_id`, `caller_job`, host memory, `dirty`,
      `partition`, a result's `workflow` and `child_run_id`, `commands`, and
      the command cost's optional fields) are omitted rather than sent as
      null. `command`, `exit_code` and `error` are required and may be null.
      Unknown keys, including `project`, `account_id`, `graph`, `ci` and
      `source.branch`, are rejected. Duplicate keys, U+0000, non-integer
      numbers, integers beyond 2^53 - 1, and objects or arrays nested more
      than 8 levels deep are `422`.
      """,
      example: WorkflowRunParts.example()
    }),
    struct?: false
  )
end
