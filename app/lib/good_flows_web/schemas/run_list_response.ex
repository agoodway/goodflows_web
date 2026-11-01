defmodule GoodFlowsWeb.Schemas.RunListResponse do
  @moduledoc "OpenAPI schema for one page of a recipe's runs, newest first, without steps."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "RunListResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.Run},
      next_cursor: %Schema{
        type: :string,
        nullable: true,
        description: "Pass as `cursor` for the next page; null on the last page"
      }
    }
  })
end
