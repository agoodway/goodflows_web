defmodule GoodFlowsWeb.Schemas.RecipeResponse do
  @moduledoc "OpenAPI schema for a single-recipe response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RecipeResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.Recipe}
  })
end
