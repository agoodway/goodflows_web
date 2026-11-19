defmodule GoodFlowsWeb.Schemas.ProjectRequest do
  @moduledoc "OpenAPI schema for creating a project."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.ProjectUpdateRequest
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ProjectRequest",
    description: """
    `slug` is 1 to 64 bytes of lowercase letters, digits, `_`, and `-`,
    starting with a letter or digit, and is unique within the account. It
    cannot be changed later. `default_branch` (default `main`) names the
    project's fallback cache scope: 1 to 256 bytes with no control
    characters, not validated as a Git branch name.
    """,
    type: :object,
    required: [:slug],
    properties: %{
      slug: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 64,
        pattern: "^[a-z0-9][a-z0-9_-]*$"
      },
      default_branch: ProjectUpdateRequest.default_branch()
    },
    example: %{"slug" => "goodcases"}
  })
end
