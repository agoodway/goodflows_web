defmodule GoodFlowsWeb.Schemas.StoredChangeFile do
  @moduledoc "OpenAPI schema: one file of a stored change version."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeFile",
    description: "A file's path in the change directory and its text, byte for byte as pushed.",
    type: :object,
    required: [:path, :text],
    properties: %{path: %Schema{type: :string}, text: %Schema{type: :string}}
  })
end
