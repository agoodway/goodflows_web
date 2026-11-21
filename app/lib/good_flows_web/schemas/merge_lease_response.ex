defmodule GoodFlowsWeb.Schemas.MergeLeaseResponse do
  @moduledoc "OpenAPI schema for one merge lease."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "MergeLeaseResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.MergeLease}
  })
end
