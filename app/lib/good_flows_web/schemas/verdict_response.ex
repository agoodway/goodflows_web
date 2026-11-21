defmodule GoodFlowsWeb.Schemas.VerdictResponse do
  @moduledoc "OpenAPI schema for a verdict read."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VerdictResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.Verdict}
  })
end
