defmodule GoodFlowsWeb.Schemas.WorkflowRunRequest do
  @moduledoc """
  OpenAPI schema for a workflow-run upload body. There is no `project` or
  `account_id` property: the project is the path slug and the account comes
  from the API key. Optional keys are absent or a value, never null.
  Nullable keys are required and may be null.
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
      One goodflows run-history document at `schema_version` 1, optionally
      with the CLI upload envelope: `source.branch`, `ci` and `graph`.
      Required keys must be present. Optional keys (`environment`,
      `requested_jobs`, `source`, `ci`, `graph`, `parent_run_id`,
      `caller_job`, host memory, `dirty`, `branch`, `partition`, a result's
      `workflow` and `child_run_id`, `commands`, a graph job's `call`, and
      the optional fields of command costs and `ci`) are omitted rather than
      sent as null. Nullable keys are always present and may be null: a
      result's `command`, `exit_code` and `error`, a graph job's `command`,
      `partitions`, `timeout_secs` and `condition`, and a graph step's
      `shell` and `condition`. When `graph` is present, job names are
      unique, every `depends_on` entry names a graph job, there is no
      dependency cycle, and every result `name` is a graph job. A called
      workflow is referenced by `call.graph_sha256`, never inlined. Unknown
      keys, including `project` and `account_id`, are rejected. Duplicate
      keys, U+0000, non-integer numbers, integers beyond 2^53 - 1, and
      objects or arrays nested more than 8 levels deep are `422`.
      """,
      example: WorkflowRunParts.example()
    }),
    struct?: false
  )
end
