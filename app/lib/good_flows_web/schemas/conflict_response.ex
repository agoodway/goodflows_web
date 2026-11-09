defmodule GoodFlowsWeb.Schemas.ConflictResponse do
  @moduledoc """
  OpenAPI schema for a `409 Conflict` whose body is only a `detail` message:
  deleting a recipe that has an active run, deleting a project that still
  has recipes, test reports or workflow runs, or uploading a different test
  report or workflow run under a stored identity.
  """
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ConflictResponse",
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:detail],
        properties: %{detail: %Schema{type: :string}}
      }
    },
    example: %{"errors" => %{"detail" => "The recipe has a queued or running run"}}
  })
end
