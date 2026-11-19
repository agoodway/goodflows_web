defmodule GoodFlowsWeb.Schemas.ProjectUpdateRequest do
  @moduledoc "OpenAPI schema for updating a project's default branch."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @default_branch %Schema{
    type: :string,
    minLength: 1,
    description:
      "The fallback cache scope: 1 to 256 UTF-8 bytes with no control characters. " <>
        "Not validated as a Git branch name.",
    example: "main"
  }

  @doc "The `default_branch` property, shared with `ProjectRequest`."
  @spec default_branch() :: Schema.t()
  def default_branch, do: @default_branch

  OpenApiSpex.schema(%{
    title: "ProjectUpdateRequest",
    description: "Only `default_branch` may be sent. Any other key, `slug` included, is `422`.",
    type: :object,
    required: [:default_branch],
    additionalProperties: false,
    properties: %{default_branch: @default_branch},
    example: %{"default_branch" => "trunk"}
  })
end
