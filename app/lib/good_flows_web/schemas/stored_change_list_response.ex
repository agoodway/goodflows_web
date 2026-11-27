defmodule GoodFlowsWeb.Schemas.StoredChangeListResponse do
  @moduledoc "OpenAPI schema: one page of a project's stored changes."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.StoredChangeLink
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeListResponse",
    description:
      "Stored changes by latest version, newest latest push first, ties by id. " <>
        "A change pushed again while a client pages may be missed or repeated; follow the " <>
        "project event feed for live updates.",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          required: ~w(change_id version status size door capabilities depends_on last_pushed_at
               change_requests)a,
          properties: %{
            change_id: %Schema{type: :string},
            version: %Schema{type: :integer, minimum: 1, description: "The latest version"},
            status: %Schema{type: :string, enum: ~w(proposed approved archived)},
            size: %Schema{type: :string, nullable: true},
            door: %Schema{type: :string, nullable: true},
            capabilities: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
            depends_on: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
            last_pushed_at: %Schema{type: :string, format: :"date-time"},
            change_requests: %Schema{
              type: :array,
              items: StoredChangeLink,
              description:
                "The project's change requests whose `change_id` is this id, by number; " <>
                  "empty when none"
            }
          }
        }
      },
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end
