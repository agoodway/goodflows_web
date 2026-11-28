defmodule GoodFlowsWeb.Schemas.StoredChangeArchivedResponse do
  @moduledoc "OpenAPI schema: the `409` for a push over an archived stored change."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeArchivedResponse",
    description: "The change's latest version is `archived`; `error` is `change_archived`.",
    type: :object,
    required: [:errors],
    properties: %{
      errors: %Schema{
        type: :object,
        required: [:error, :detail],
        properties: %{
          error: %Schema{type: :string, enum: ["change_archived"]},
          detail: %Schema{type: :string}
        }
      }
    },
    example: %{
      "errors" => %{
        "error" => "change_archived",
        "detail" =>
          "add-login is archived and takes no further pushes; give a new change a new id"
      }
    }
  })
end
