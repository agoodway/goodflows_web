defmodule GoodFlowsWeb.Schemas.ErrorResponse do
  @moduledoc "OpenAPI schema for JSON error bodies rendered by `GoodFlowsWeb.ErrorJSON`."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ErrorResponse",
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:detail],
        properties: %{detail: %Schema{type: :string}}
      }
    },
    example: %{"errors" => %{"detail" => "Unauthorized - valid API key required"}}
  })
end
