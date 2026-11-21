defmodule GoodFlowsWeb.Schemas.ReviewPolicyVersionListResponse do
  @moduledoc "OpenAPI schema for one page of review policy versions."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ReviewPolicyVersionListResponse",
    type: :object,
    required: [:data, :next_cursor],
    properties: %{
      data: %Schema{type: :array, items: GoodFlowsWeb.Schemas.ReviewPolicyVersion},
      next_cursor: %Schema{type: :string, nullable: true}
    }
  })
end
