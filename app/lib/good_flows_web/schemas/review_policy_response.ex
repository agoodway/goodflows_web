defmodule GoodFlowsWeb.Schemas.ReviewPolicyResponse do
  @moduledoc "OpenAPI schema for a single review policy version response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ReviewPolicyResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.ReviewPolicyVersion}
  })
end
