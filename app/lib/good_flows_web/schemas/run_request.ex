defmodule GoodFlowsWeb.Schemas.RunRequest do
  @moduledoc "OpenAPI schema for starting a run (or dry run) of a recipe phase."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RunRequest",
    type: :object,
    required: [:phase],
    properties: %{
      phase: %Schema{type: :string, enum: ["setup", "start", "stop", "teardown"]},
      branch: %Schema{
        type: :string,
        maxLength: 255,
        pattern: "^[A-Za-z0-9][A-Za-z0-9._/+-]*$",
        description: "Fills {{branch}} and {{branch_slug}}"
      },
      commit: %Schema{
        type: :string,
        maxLength: 255,
        pattern: "^[A-Za-z0-9][A-Za-z0-9._/+-]*$",
        description: "Fills {{commit}} (a commit SHA or other ref)"
      },
      remote: %Schema{
        type: :string,
        maxLength: 1024,
        pattern: "^[A-Za-z0-9][A-Za-z0-9._:/@%+-]*$",
        description: "Fills {{remote}}"
      },
      sprite: %Schema{
        type: :string,
        maxLength: 255,
        description:
          "Sprite name template overriding the recipe name; must expand to lowercase " <>
            "letters, digits, and hyphens (starting with a letter or digit, at most 63 characters)"
      },
      no_create: %Schema{type: :boolean, description: "setup only: fail if the VM is missing"},
      no_destroy: %Schema{type: :boolean, description: "teardown only: keep the VM"},
      dry_run: %Schema{
        type: :boolean,
        description: "Return the plan (200) without creating a run or touching the VM"
      }
    },
    example: %{"phase" => "setup", "branch" => "feat/x", "commit" => "abc123"}
  })
end
