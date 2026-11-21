defmodule GoodFlowsWeb.Schemas.Defect do
  @moduledoc "OpenAPI schema for a recorded defect."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Defect",
    type: :object,
    required: [:id, :change_request, :commit, :attribution, :severity, :ticket, :recorded_at],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      change_request: %Schema{
        type: :integer,
        nullable: true,
        description: "The attributed change request number"
      },
      commit: %Schema{type: :string, nullable: true},
      attribution: %Schema{type: :string, enum: ~w(change_request commit unattributed)},
      severity: %Schema{type: :string, nullable: true, enum: ~w(low medium high critical)},
      ticket: %Schema{type: :string, nullable: true, description: "Null for public keys"},
      recorded_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
