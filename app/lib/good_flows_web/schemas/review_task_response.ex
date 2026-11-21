defmodule GoodFlowsWeb.Schemas.ReviewTaskResponse do
  @moduledoc "OpenAPI schema for one review task."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ReviewTaskResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.ReviewTask}
  })
end
