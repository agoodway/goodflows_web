defmodule GoodFlowsWeb.Schemas.StoredChangeVersion do
  @moduledoc """
  OpenAPI schema: one stored change version without its files.
  `properties/0` and `required/0` are shared with the responses that add
  fields to it.
  """
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.StoredChangeSource
  alias OpenApiSpex.Schema

  @properties %{
    change_id: %Schema{type: :string, pattern: "^[a-z0-9][a-z0-9-]*$", maxLength: 64},
    version: %Schema{type: :integer, minimum: 1},
    status: %Schema{type: :string, enum: ~w(proposed approved archived)},
    size: %Schema{type: :string, enum: ~w(small project), nullable: true},
    door: %Schema{type: :string, enum: ~w(one_way two_way), nullable: true},
    capabilities: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
    depends_on: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
    pushed_at: %Schema{type: :string, format: :"date-time"},
    source: StoredChangeSource,
    pushed_by: %Schema{
      type: :object,
      nullable: true,
      description: "Null for public keys; `user_id` null once the membership is gone",
      properties: %{user_id: %Schema{type: :string, nullable: true}}
    }
  }

  @required [
    :change_id,
    :version,
    :status,
    :size,
    :door,
    :capabilities,
    :depends_on,
    :pushed_at,
    :source,
    :pushed_by
  ]

  @doc "The version's properties."
  @spec properties() :: map()
  def properties, do: @properties

  @doc "The version's required properties."
  @spec required() :: [atom()]
  def required, do: @required

  OpenApiSpex.schema(%{
    title: "StoredChangeVersion",
    description:
      "One version: `size`, `door`, `capabilities` and `depends_on` are read from " <>
        "`change.md` and null when missing or malformed.",
    type: :object,
    required: @required,
    properties: @properties
  })
end
