defmodule GoodFlowsWeb.Schemas.ReviewPacketResponse do
  @moduledoc "OpenAPI schema for a change request's review packet."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @context %Schema{
    type: :object,
    required: [:rule, :subject, :message],
    properties: %{
      rule: %Schema{type: :string},
      subject: %Schema{type: :array, items: %Schema{type: :string}},
      message: %Schema{type: :string}
    }
  }

  OpenApiSpex.schema(%{
    title: "ReviewPacketResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [
          :number,
          :head,
          :base,
          :policy_version,
          :verdict,
          :passed,
          :pending,
          :blocked,
          :items
        ],
        properties: %{
          number: %Schema{type: :integer},
          head: %Schema{type: :string, nullable: true},
          base: %Schema{
            type: :object,
            nullable: true,
            properties: %{
              branch: %Schema{type: :string},
              merge_base: %Schema{type: :string}
            }
          },
          policy_version: %Schema{type: :integer},
          verdict: %Schema{type: :string, enum: ~w(pending blocked needs_review mergeable)},
          passed: %Schema{
            type: :object,
            properties: %{
              must: %Schema{type: :integer},
              should: %Schema{type: :integer},
              workflows: %Schema{type: :array, items: %Schema{type: :string}}
            }
          },
          pending: %Schema{
            type: :array,
            items: @context,
            description: "Context only; not answerable"
          },
          blocked: %Schema{
            type: :array,
            items: @context,
            description: "Context only; not answerable"
          },
          items: %Schema{type: :array, items: GoodFlowsWeb.Schemas.ReviewItem}
        }
      }
    }
  })
end
