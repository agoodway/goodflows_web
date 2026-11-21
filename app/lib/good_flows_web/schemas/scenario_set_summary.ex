defmodule GoodFlowsWeb.Schemas.ScenarioSetSummary do
  @moduledoc "OpenAPI schema: One set kind: its current version (or null) and all versions."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ScenarioSetSummary",
    description: "One set kind: its current version (or null) and all versions.",
    type: :object,
    required: [:current, :versions],
    properties: %{
      current: %Schema{allOf: [GoodFlowsWeb.Schemas.ScenarioSetVersion], nullable: true},
      versions: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            version: %Schema{type: :integer},
            digest: %Schema{type: :string},
            inserted_at: %Schema{type: :string, format: :"date-time"},
            approved: %Schema{type: :boolean}
          }
        }
      }
    }
  })
end
