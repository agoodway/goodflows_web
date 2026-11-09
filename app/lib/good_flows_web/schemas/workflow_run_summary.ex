defmodule GoodFlowsWeb.Schemas.WorkflowRunSummary do
  @moduledoc """
  OpenAPI schema for one workflow-run summary. Generated from the same field
  tables as the upload document.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.WorkflowRunParts

  @dialyzer {:nowarn_function, schema: 0}

  OpenApiSpex.schema(
    WorkflowRunParts.summary()
    |> Map.from_struct()
    |> Map.put(:title, "WorkflowRunSummary"),
    struct?: false
  )
end
