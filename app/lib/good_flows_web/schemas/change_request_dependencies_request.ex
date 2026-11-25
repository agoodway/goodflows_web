defmodule GoodFlowsWeb.Schemas.ChangeRequestDependenciesRequest do
  @moduledoc "OpenAPI schema for replacing a change request's dependencies."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ChangeRequestDependenciesRequest",
    type: :object,
    additionalProperties: false,
    required: [:change_ids],
    properties: %{
      change_ids: %Schema{
        type: :array,
        maxItems: 50,
        uniqueItems: true,
        description:
          "The change ids this change request waits for; `[]` clears them. Not the " <>
            "change request's own `change_id`",
        items: %Schema{
          type: :string,
          minLength: 1,
          maxLength: 64,
          pattern: "^[a-z0-9][a-z0-9-]*$"
        }
      }
    }
  })
end
