defmodule GoodFlowsWeb.Schemas.ChangeRequest do
  @moduledoc """
  OpenAPI schema for a change request. Single-record responses also carry
  `description`, `verdict` and `history`; list entries do not.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.{ChangeRequestHistoryEntry, ChangeRequestMerge, Verdict}
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ChangeRequest",
    type: :object,
    required: [
      :id,
      :number,
      :title,
      :state,
      :source_branch,
      :target_branch,
      :change_id,
      :links,
      :head,
      :parent,
      :opened_by,
      :merge,
      :inserted_at,
      :updated_at
    ],
    properties: %{
      id: %Schema{type: :string, format: :uuid},
      number: %Schema{type: :integer, minimum: 1},
      title: %Schema{type: :string},
      state: %Schema{type: :string, enum: ~w(draft open merged closed)},
      source_branch: %Schema{type: :string},
      target_branch: %Schema{type: :string},
      change_id: %Schema{type: :string, nullable: true},
      links: %Schema{
        type: :object,
        nullable: true,
        description: "Public keys see `threads` as null"
      },
      head: %Schema{type: :string, nullable: true, description: "The last reported head"},
      parent: %Schema{
        type: :integer,
        nullable: true,
        description: "The parent change request's number (a stacked change request), or null"
      },
      opened_by: %Schema{
        type: :object,
        properties: %{user_id: %Schema{type: :string, format: :uuid, nullable: true}}
      },
      merge: ChangeRequestMerge,
      description: %Schema{
        type: :string,
        nullable: true,
        description: "The claims file for the current head (null for public keys)"
      },
      verdict: %Schema{allOf: [Verdict], nullable: true},
      history: %Schema{type: :array, items: ChangeRequestHistoryEntry},
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
