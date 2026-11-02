defmodule GoodFlowsWeb.Schemas.RecipeListResponse do
  @moduledoc "OpenAPI schema for the recipe list."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RecipeListResponse",
    type: :object,
    required: [:data],
    properties: %{data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.Recipe}}
  })
end
