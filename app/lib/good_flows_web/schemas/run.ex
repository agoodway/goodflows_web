defmodule GoodFlowsWeb.Schemas.Run do
  @moduledoc "OpenAPI schema for a run. `steps` is present only on `GET /runs/:id`."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Run",
    type: :object,
    required: [:id, :status, :phase, :sprite_name, :inputs, :no_create, :no_destroy],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      recipe_id: %Schema{type: :string, format: :uuid, nullable: true},
      project: %Schema{
        type: :string,
        nullable: true,
        description:
          "Slug of the recipe's project, for building " <>
            "`/api/v1/projects/{project}/recipes/{recipe_id}` (null once the recipe is deleted)"
      },
      status: %Schema{type: :string, enum: ["queued", "running", "succeeded", "failed"]},
      phase: %Schema{type: :string, enum: ["setup", "start", "stop", "teardown"]},
      sprite_name: %Schema{type: :string},
      inputs: %Schema{
        type: :object,
        properties: %{
          branch: %Schema{type: :string, nullable: true},
          commit: %Schema{type: :string, nullable: true},
          remote: %Schema{type: :string, nullable: true},
          sprite: %Schema{type: :string, nullable: true}
        }
      },
      no_create: %Schema{type: :boolean},
      no_destroy: %Schema{type: :boolean},
      error: %Schema{type: :string, nullable: true},
      started_by_api_key_id: %Schema{
        type: :string,
        format: :uuid,
        nullable: true,
        description: "The API key that started the run (null once that key is deleted)"
      },
      started_at: %Schema{type: :string, format: :"date-time", nullable: true},
      finished_at: %Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"},
      steps: %Schema{type: :array, items: GoodFlowsWeb.Schemas.RunStep}
    }
  })
end
