defmodule GoodFlowsWeb.Schemas.DefectRequest do
  @moduledoc "OpenAPI schema for recording a defect."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "DefectRequest",
    description:
      "Exactly one of `change_request` or `commit`; both or neither is `422` on `body`.",
    type: :object,
    additionalProperties: false,
    properties: %{
      change_request: %Schema{
        type: :integer,
        minimum: 1,
        description: "A change request number of the project"
      },
      commit: %Schema{
        type: :string,
        pattern: "^([0-9a-f]{40}|[0-9a-f]{64})$",
        description:
          "Attributed to the earliest merged change request whose merged head's " <>
            "`git-facts` commits list it, else unattributed"
      },
      severity: %Schema{type: :string, enum: ~w(low medium high critical)},
      ticket: %Schema{type: :string, minLength: 1, maxLength: 200}
    }
  })
end
