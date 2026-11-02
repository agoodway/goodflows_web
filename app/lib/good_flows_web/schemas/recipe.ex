defmodule GoodFlowsWeb.Schemas.Recipe do
  @moduledoc "OpenAPI schema for a stored Spry recipe."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @lines %Schema{type: :array, items: %Schema{type: :string}}

  OpenApiSpex.schema(%{
    title: "Recipe",
    description: """
    A sprite name template and the in-VM shell lines run by each lifecycle
    phase, belonging to one project of the account.
    """,
    type: :object,
    required: [
      :id,
      :project_id,
      :project,
      :name,
      :setup,
      :start,
      :stop,
      :teardown,
      :inserted_at,
      :updated_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      project_id: %Schema{type: :string, format: :uuid, description: "The owning project's id"},
      project: %Schema{type: :string, description: "The owning project's slug"},
      name: %Schema{type: :string, description: "Sprite name template"},
      setup: @lines,
      start: @lines,
      stop: @lines,
      teardown: @lines,
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    },
    example: %{
      "id" => "6c1f0a52-8d2b-4f6e-9c3a-1b2d3e4f5a6b",
      "project_id" => "2b7e1d4c-5a6f-4c3b-8e9d-0a1b2c3d4e5f",
      "project" => "goodcases",
      "name" => "myapp-{{branch_slug}}",
      "setup" => ["git clone {{remote}} app", "cd app && git checkout {{commit}}"],
      "start" => ["cd app && bin/server -d"],
      "stop" => ["pkill -f bin/server"],
      "teardown" => [],
      "inserted_at" => "2026-11-01T12:00:00.000000Z",
      "updated_at" => "2026-11-01T12:00:00.000000Z"
    }
  })
end
