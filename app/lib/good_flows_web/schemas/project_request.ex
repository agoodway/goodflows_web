defmodule GoodFlowsWeb.Schemas.ProjectRequest do
  @moduledoc "OpenAPI schema for creating a project."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ProjectRequest",
    description: """
    `slug` is 1 to 64 bytes of lowercase letters, digits, `_`, and `-`,
    starting with a letter or digit, and is unique within the account. It
    cannot be changed later.
    """,
    type: :object,
    required: [:slug],
    properties: %{
      slug: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 64,
        pattern: "^[a-z0-9][a-z0-9_-]*$"
      }
    },
    example: %{"slug" => "goodcases"}
  })
end
