defmodule GoodFlowsWeb.Schemas.ReviewAnswerResponse do
  @moduledoc "OpenAPI schema for a stored answer."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ReviewAnswerResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.ReviewAnswer}
  })
end
