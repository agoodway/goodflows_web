defmodule GoodFlowsWeb.Schemas.RecipeRequest do
  @moduledoc "OpenAPI schema for creating or replacing a recipe."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @lines %Schema{
    type: :array,
    items: %Schema{type: :string, minLength: 1, maxLength: 10_000},
    maxItems: 500,
    description:
      "Non-empty shell lines run inside the VM (at most 500 per phase). Host steps are not supported."
  }

  OpenApiSpex.schema(%{
    title: "RecipeRequest",
    description: """
    Full recipe body. `PUT` replaces the recipe: omitted lists become empty.
    `name` may use `{{branch}}`, `{{branch_slug}}`, `{{commit}}`, and `{{remote}}`;
    step lines may also use `{{sprite}}`. There is no `org` or `project`
    field: the project comes from the URL, and either key is rejected.

    `name` is the sprite name template and is unique per project; another
    project of the account may reuse it. Its
    literal text must be lowercase letters, digits, and hyphens (starting
    with a letter or digit), and the expanded name must be at most 63
    characters; prefer `{{branch_slug}}` over `{{branch}}`.
    """,
    type: :object,
    required: [:name],
    properties: %{
      name: %Schema{type: :string, minLength: 1, maxLength: 255},
      setup: @lines,
      start: @lines,
      stop: @lines,
      teardown: @lines
    },
    example: %{
      "name" => "myapp-{{branch_slug}}",
      "setup" => ["git clone {{remote}} app"],
      "start" => ["cd app && bin/server -d"]
    }
  })
end
