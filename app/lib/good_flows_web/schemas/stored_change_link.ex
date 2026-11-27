defmodule GoodFlowsWeb.Schemas.StoredChangeLink do
  @moduledoc "OpenAPI schema: a change request linking a stored change."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangeLink",
    description: "A change request of the project whose `change_id` is the stored change's id.",
    type: :object,
    required: [:number, :state],
    properties: %{
      number: %Schema{type: :integer, minimum: 1},
      state: %Schema{type: :string, enum: ~w(draft open closed merged)}
    }
  })
end
