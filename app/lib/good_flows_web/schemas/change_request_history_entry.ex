defmodule GoodFlowsWeb.Schemas.ChangeRequestHistoryEntry do
  @moduledoc "OpenAPI schema for one recorded state change."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @states ~w(draft open merged closed)

  OpenApiSpex.schema(%{
    title: "ChangeRequestHistoryEntry",
    type: :object,
    required: [:from_state, :to_state, :user_id, :inserted_at],
    properties: %{
      from_state: %Schema{type: :string, enum: @states},
      to_state: %Schema{type: :string, enum: @states},
      user_id: %Schema{type: :string, format: :uuid, nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
