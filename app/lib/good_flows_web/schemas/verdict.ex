defmodule GoodFlowsWeb.Schemas.Verdict do
  @moduledoc "OpenAPI schema for a change request verdict."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.VerdictReason
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Verdict",
    description: "Act on a verdict only while its `head` and `policy_version` are still current.",
    type: :object,
    required: [:state, :head, :policy_version, :reasons, :inputs, :computed_at],
    properties: %{
      state: %Schema{type: :string, enum: ~w(pending blocked needs_review mergeable)},
      head: %Schema{type: :string, nullable: true},
      policy_version: %Schema{type: :integer, minimum: 0},
      reasons: %Schema{type: :array, items: VerdictReason},
      inputs: %Schema{type: :object, description: "Digests of the inputs"},
      computed_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
