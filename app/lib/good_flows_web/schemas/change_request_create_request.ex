defmodule GoodFlowsWeb.Schemas.ChangeRequestCreateRequest do
  @moduledoc "OpenAPI schema for opening a change request."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.WorkflowRunParts
  alias OpenApiSpex.Schema

  @text %Schema{type: :string, minLength: 1, maxLength: 256, description: "No control characters"}

  OpenApiSpex.schema(%{
    title: "ChangeRequestCreateRequest",
    type: :object,
    additionalProperties: false,
    required: [:title, :source_branch],
    properties: %{
      title: @text,
      source_branch: @text,
      target_branch: %Schema{@text | description: "Defaults to the project's `default_branch`"},
      change_id: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 64,
        pattern: "^[a-z0-9][a-z0-9-]*$"
      },
      links: WorkflowRunParts.document().properties["links"]
    }
  })
end
