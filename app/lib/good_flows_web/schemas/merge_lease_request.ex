defmodule GoodFlowsWeb.Schemas.MergeLeaseRequest do
  @moduledoc "OpenAPI schema for a merge lease acquire."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "MergeLeaseRequest",
    type: :object,
    additionalProperties: false,
    required: [:head, :base],
    properties: %{
      head: %Schema{
        type: :string,
        pattern: "^([0-9a-f]{40}|[0-9a-f]{64})$",
        description: "The change request's last reported head"
      },
      base: %Schema{
        type: :string,
        pattern: "^([0-9a-f]{40}|[0-9a-f]{64})$",
        description: "The target branch commit the client will merge onto"
      }
    }
  })
end
