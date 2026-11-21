defmodule GoodFlowsWeb.Schemas.ScenarioSetCompareResponse do
  @moduledoc "OpenAPI schema: Changes from version `from` to `to` by scenario ID, weakening changes first."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ScenarioSetCompareResponse",
    description: "Changes from version `from` to `to` by scenario ID, weakening changes first.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        properties: %{
          source: %Schema{type: :string, enum: ~w(intent diff)},
          from: %Schema{type: :integer, nullable: true},
          to: %Schema{type: :integer},
          changes: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              required: [:id, :change, :weakening, :from_priority, :to_priority],
              properties: %{
                id: %Schema{type: :string},
                change: %Schema{type: :string, enum: ~w(removed demoted changed added)},
                weakening: %Schema{type: :boolean},
                from_priority: %Schema{type: :string, nullable: true},
                to_priority: %Schema{type: :string, nullable: true}
              }
            }
          }
        }
      }
    }
  })
end
