defmodule GoodFlowsWeb.Schemas.StoredChangeSource do
  @moduledoc "OpenAPI schema: where a stored change version was pushed from."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeSource",
    description:
      "Where the push came from, stored as given and never checked: `commit` is null in a " <>
        "repository without commits, `branch` null on a detached HEAD.",
    type: :object,
    required: [:commit, :branch, :dirty],
    additionalProperties: false,
    properties: %{
      commit: %Schema{type: :string, pattern: "^[0-9a-f]{7,64}$", nullable: true},
      branch: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 256,
        nullable: true,
        description: "1 to 256 bytes without control characters"
      },
      dirty: %Schema{type: :boolean}
    }
  })
end
