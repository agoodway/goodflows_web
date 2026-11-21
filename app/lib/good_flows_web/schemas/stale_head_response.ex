defmodule GoodFlowsWeb.Schemas.StaleHeadResponse do
  @moduledoc "OpenAPI schema for a `409` of an answer: not live, or not the current head."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StaleHeadResponse",
    description:
      "The change request is not `draft` or `open`, or `head` is not its current head " <>
        "(then `head` is the current head, or null before any `git-facts` report).",
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:detail],
        properties: %{
          detail: %Schema{type: :string},
          head: %Schema{type: :string, nullable: true}
        }
      }
    }
  })
end
