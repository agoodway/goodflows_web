defmodule GoodFlowsWeb.Schemas.MergeLease do
  @moduledoc "OpenAPI schema for a merge slot lease."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "MergeLease",
    description:
      "A lease on the merge slot of the project's `target_branch`. It holds the slot " <>
        "while `state` is `active` and `expires_at` has not passed.",
    type: :object,
    required: [
      :id,
      :change_request,
      :target_branch,
      :head,
      :base,
      :state,
      :release_reason,
      :acquired_at,
      :expires_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      change_request: %Schema{type: :integer, minimum: 1, description: "Change request number"},
      target_branch: %Schema{type: :string},
      head: %Schema{type: :string},
      base: %Schema{type: :string},
      state: %Schema{type: :string, enum: ~w(active released expired)},
      release_reason: %Schema{
        type: :string,
        nullable: true,
        enum: ~w(released merged closed),
        description: "Set when `state` is `released`"
      },
      acquired_at: %Schema{type: :string, format: :"date-time"},
      expires_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
