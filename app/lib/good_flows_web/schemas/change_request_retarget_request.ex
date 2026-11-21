defmodule GoodFlowsWeb.Schemas.ChangeRequestRetargetRequest do
  @moduledoc "OpenAPI schema for retargeting a change request."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ChangeRequestRetargetRequest",
    type: :object,
    additionalProperties: false,
    required: [:target_branch],
    properties: %{target_branch: %Schema{type: :string, minLength: 1, maxLength: 256}}
  })
end
