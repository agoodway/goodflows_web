defmodule GoodFlowsWeb.Schemas.ValidationErrorResponse do
  @moduledoc "OpenAPI schema for `422` bodies rendered from changeset or plan errors."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ValidationErrorResponse",
    description:
      "Errors keyed by field. Phase items use indexed keys such as `setup[2]`; " <>
        "plan errors that are not tied to a field use `detail`.",
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        additionalProperties: %Schema{
          oneOf: [%Schema{type: :array, items: %Schema{type: :string}}, %Schema{type: :string}]
        }
      }
    },
    example: %{"errors" => %{"setup[1]" => ["host steps are not supported by the API"]}}
  })
end
