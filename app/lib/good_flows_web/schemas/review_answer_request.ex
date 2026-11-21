defmodule GoodFlowsWeb.Schemas.ReviewAnswerRequest do
  @moduledoc "OpenAPI schema for an answer to a review packet item."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ReviewAnswerRequest",
    description:
      "`head` is the current head, or null exactly when no `git-facts` report exists. " <>
        "`option` is required for `choose` and forbidden otherwise. `note` (1 to 10,000 " <>
        "bytes) is required for `reject` and `request_change`, and for them must not be " <>
        "only whitespace. Any other key is `422`.",
    type: :object,
    required: [:head, :answer],
    additionalProperties: false,
    properties: %{
      head: %Schema{type: :string, nullable: true, pattern: "^([0-9a-f]{40}|[0-9a-f]{64})$"},
      answer: %Schema{type: :string, enum: ~w(approve reject request_change choose)},
      option: %Schema{type: :string, minLength: 1},
      note: %Schema{type: :string, minLength: 1, maxLength: 10_000, nullable: true}
    }
  })
end
