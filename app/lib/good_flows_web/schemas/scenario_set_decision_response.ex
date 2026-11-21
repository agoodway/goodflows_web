defmodule GoodFlowsWeb.Schemas.ScenarioSetDecisionResponse do
  @moduledoc "OpenAPI schema: A recorded decision."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ScenarioSetDecisionResponse",
    description: "A recorded decision.",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.ScenarioSetDecision}
  })
end
