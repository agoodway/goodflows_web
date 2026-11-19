defmodule GoodFlowsWeb.Schemas.Project do
  @moduledoc "OpenAPI schema for a project."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Project",
    description: "An account-owned project addressed by its slug. Recipes belong to a project.",
    type: :object,
    required: [:id, :slug, :default_branch, :inserted_at, :updated_at],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      slug: %Schema{type: :string, description: "Project slug, unique within the account"},
      default_branch: %Schema{
        type: :string,
        description:
          "The project's fallback cache scope: lookups read the requested scope, then " <>
            "the scope equal to this value."
      },
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    },
    example: %{
      "id" => "2b7e1d4c-5a6f-4c3b-8e9d-0a1b2c3d4e5f",
      "slug" => "goodcases",
      "default_branch" => "main",
      "inserted_at" => "2026-11-01T12:00:00.000000Z",
      "updated_at" => "2026-11-01T12:00:00.000000Z"
    }
  })
end
