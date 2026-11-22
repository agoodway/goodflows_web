defmodule GoodFlowsWeb.Schemas.ScenarioSetVersion do
  @moduledoc "OpenAPI schema: One version of an intent or diff set."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ScenarioSetVersion",
    description:
      "One version of an intent or diff set. Public keys see `content`, `front_matter` and `sections` as null; `scenarios` keeps IDs and priorities.",
    type: :object,
    required: [:source, :version, :digest, :approved, :accepted, :inserted_at, :scenarios],
    properties: %{
      source: %Schema{type: :string, enum: ~w(intent diff)},
      version: %Schema{type: :integer, minimum: 1},
      digest: %Schema{type: :string, description: "Lowercase hex SHA-256 of `content`"},
      approved: %Schema{
        type: :boolean,
        description:
          "An intent version whose digest's latest decision is `approve`; false for diff"
      },
      accepted: %Schema{
        type: :boolean,
        description:
          "The digest's latest decision is `approve`. Equals `approved` for intent; a diff " <>
            "version is accepted only through `diff_set_weakened` review answers"
      },
      inserted_at: %Schema{type: :string, format: :"date-time"},
      scenarios: %Schema{
        type: :array,
        items: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string},
            priority: %Schema{type: :string, enum: ~w(must should could)}
          }
        }
      },
      content: %Schema{type: :string, nullable: true},
      front_matter: %Schema{type: :object, nullable: true},
      sections: %Schema{type: :array, items: %Schema{type: :object}, nullable: true},
      decisions: %Schema{type: :array, items: GoodFlowsWeb.Schemas.ScenarioSetDecision},
      duplicate: %Schema{
        type: :boolean,
        description: "On uploads: the digest equals the current version's"
      }
    }
  })
end
