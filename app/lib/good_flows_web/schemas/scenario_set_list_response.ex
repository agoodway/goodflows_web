defmodule GoodFlowsWeb.Schemas.ScenarioSetListResponse do
  @moduledoc "OpenAPI schema: The intent and diff sets of a change request: the current version and every version, newest first."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ScenarioSetListResponse",
    description:
      "The intent and diff sets of a change request: the current version and every version, newest first.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        properties: %{
          intent: GoodFlowsWeb.Schemas.ScenarioSetSummary,
          diff: GoodFlowsWeb.Schemas.ScenarioSetSummary
        }
      }
    }
  })
end
