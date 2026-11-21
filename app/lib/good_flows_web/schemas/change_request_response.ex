defmodule GoodFlowsWeb.Schemas.ChangeRequestResponse do
  @moduledoc "OpenAPI schema for a single change request response."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ChangeRequestResponse",
    type: :object,
    required: [:data],
    properties: %{data: GoodFlowsWeb.Schemas.ChangeRequest}
  })
end
