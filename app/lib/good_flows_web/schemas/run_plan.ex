defmodule GoodFlowsWeb.Schemas.RunPlan do
  @moduledoc "OpenAPI schema for a dry-run plan."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RunPlan",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:phase, :sprite_name, :sprite_exists, :no_create, :no_destroy, :steps],
        properties: %{
          phase: %Schema{type: :string, enum: ["setup", "start", "stop", "teardown"]},
          sprite_name: %Schema{type: :string},
          sprite_exists: %Schema{type: :boolean},
          no_create: %Schema{type: :boolean},
          no_destroy: %Schema{type: :boolean},
          inputs: %Schema{
            type: :object,
            description: "The branch, commit, remote, and sprite inputs from the request"
          },
          steps: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              required: [:index, :kind, :command],
              properties: %{
                index: %Schema{type: :integer},
                kind: %Schema{type: :string, enum: ["create", "exec", "destroy"]},
                command: %Schema{type: :string}
              }
            }
          }
        }
      }
    },
    example: %{
      "data" => %{
        "phase" => "setup",
        "sprite_name" => "app-feat-x",
        "sprite_exists" => false,
        "no_create" => false,
        "no_destroy" => false,
        "steps" => [
          %{"index" => 0, "kind" => "create", "command" => "create app-feat-x"},
          %{"index" => 1, "kind" => "exec", "command" => "echo hello"}
        ]
      }
    }
  })
end
