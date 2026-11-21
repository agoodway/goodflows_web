defmodule GoodFlowsWeb.Schemas.ReviewTask do
  @moduledoc "OpenAPI schema for one review task."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ReviewTask",
    description:
      "Created by a `request_change` or `reject` answer. A new head, or a later answer to " <>
        "the item at the same head, makes an `open` task `stale`; it keeps its note and head.",
    type: :object,
    required: [:id, :number, :item_id, :kind, :answer, :note, :head, :state],
    properties: %{
      id: %Schema{type: :string},
      number: %Schema{type: :integer},
      item_id: %Schema{type: :string},
      kind: %Schema{type: :string},
      answer: %Schema{type: :string, enum: ~w(reject request_change)},
      note: %Schema{type: :string},
      head: %Schema{type: :string, nullable: true},
      state: %Schema{type: :string, enum: ~w(open stale done)},
      created_by: %Schema{
        type: :object,
        properties: %{user_id: %Schema{type: :string, nullable: true}}
      },
      created_at: %Schema{type: :string, format: :"date-time"},
      done_by: %Schema{
        type: :object,
        nullable: true,
        properties: %{user_id: %Schema{type: :string, nullable: true}}
      },
      done_at: %Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end
