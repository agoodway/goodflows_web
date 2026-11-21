defmodule GoodFlowsWeb.Schemas.EventsGoneResponse do
  @moduledoc "OpenAPI schema for the `410` of a feed read whose cursor precedes deleted events."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "EventsGoneResponse",
    description:
      "Events after `after` were deleted by retention. Resync from current state, then " <>
        "read with `after` set to `latest_cursor`.",
    type: :object,
    required: [:errors, :latest_cursor],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:detail],
        properties: %{detail: %Schema{type: :string}}
      },
      latest_cursor: %Schema{
        type: :integer,
        nullable: true,
        description: "The project's newest event `id`, or null"
      }
    }
  })
end
