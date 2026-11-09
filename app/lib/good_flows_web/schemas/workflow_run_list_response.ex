defmodule GoodFlowsWeb.Schemas.WorkflowRunListResponse do
  @moduledoc """
  OpenAPI schema for one page of a project's workflow runs, newest
  `started_at` first.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.WorkflowRunSummary
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "WorkflowRunListResponse",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{type: :array, items: WorkflowRunSummary},
      next_cursor: %Schema{
        type: :string,
        nullable: true,
        description:
          "Pass as `cursor` for the next page. Null on the last page. A run " <>
            "stored after this page was read does not appear here."
      }
    }
  })
end
