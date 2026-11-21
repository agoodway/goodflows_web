defmodule GoodFlowsWeb.Schemas.ProjectEventListResponse do
  @moduledoc "OpenAPI schema for one page of the project event feed."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ProjectEventListResponse",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.ProjectEvent},
      next_cursor: %Schema{
        type: :integer,
        nullable: true,
        description: "The last returned event's `id`, or the given `after` when none is returned"
      }
    }
  })
end
