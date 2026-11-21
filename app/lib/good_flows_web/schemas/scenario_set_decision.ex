defmodule GoodFlowsWeb.Schemas.ScenarioSetDecision do
  @moduledoc "OpenAPI schema: An approve or reject decision on an intent set digest."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ScenarioSetDecision",
    description:
      "An approve or reject decision on an intent set digest. Public keys see `note` and `decided_by.user_id` as null.",
    type: :object,
    required: [:decision, :digest, :note, :decided_by, :decided_at, :channel],
    properties: %{
      decision: %Schema{type: :string, enum: ~w(approve reject)},
      digest: %Schema{type: :string},
      note: %Schema{type: :string, nullable: true},
      decided_by: %Schema{
        type: :object,
        properties: %{user_id: %Schema{type: :string, nullable: true}}
      },
      decided_at: %Schema{type: :string, format: :"date-time"},
      channel: %Schema{type: :string, enum: ["cli"]}
    }
  })
end
