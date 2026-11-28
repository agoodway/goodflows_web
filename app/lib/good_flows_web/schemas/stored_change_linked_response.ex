defmodule GoodFlowsWeb.Schemas.StoredChangeLinkedResponse do
  @moduledoc "OpenAPI schema: a stored change delete refused because change requests link it."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.StoredChangeLink
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeLinkedResponse",
    description:
      "`detail` and every change request of the project, in any state, linking the id.",
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:detail, :change_requests],
        properties: %{
          detail: %Schema{type: :string},
          change_requests: %Schema{type: :array, items: StoredChangeLink}
        }
      }
    }
  })
end
