defmodule GoodFlowsWeb.Schemas.ReviewAnswer do
  @moduledoc "OpenAPI schema for one stored review answer."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ReviewAnswer",
    type: :object,
    required: [:id, :item_id, :kind, :rule, :head, :answer, :option, :note, :channel],
    properties: %{
      id: %Schema{type: :string},
      item_id: %Schema{type: :string},
      kind: %Schema{type: :string},
      rule: %Schema{type: :string},
      head: %Schema{type: :string, nullable: true},
      answer: %Schema{type: :string, enum: ~w(approve reject request_change choose)},
      option: %Schema{type: :string, nullable: true},
      note: %Schema{type: :string, nullable: true},
      channel: %Schema{type: :string, enum: ["cli"]},
      answered_by: %Schema{
        type: :object,
        properties: %{
          user_id: %Schema{type: :string, nullable: true},
          key_id: %Schema{type: :string, nullable: true}
        }
      },
      inserted_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
