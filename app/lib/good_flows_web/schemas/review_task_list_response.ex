defmodule GoodFlowsWeb.Schemas.ReviewTaskListResponse do
  @moduledoc "OpenAPI schema for a change request's review tasks, oldest first."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ReviewTaskListResponse",
    type: :object,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.ReviewTask}}
  })
end
