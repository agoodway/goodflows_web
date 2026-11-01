defmodule GoodFlowsWeb.Schemas.MeResponse do
  @moduledoc "OpenAPI schema for `GET /api/v1/me`."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "MeResponse",
    description: "The account, user, and API key behind the request's credentials.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [:account, :user, :role, :api_key],
        properties: %{
          account: %Schema{
            type: :object,
            required: [:id, :name, :slug],
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              name: %Schema{type: :string},
              slug: %Schema{type: :string}
            }
          },
          user: %Schema{
            type: :object,
            required: [:id, :email],
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              email: %Schema{type: :string, format: :email}
            }
          },
          role: %Schema{type: :string, enum: ["owner", "admin", "member"]},
          api_key: %Schema{
            type: :object,
            required: [:id, :name, :type, :token_prefix],
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              name: %Schema{type: :string},
              type: %Schema{type: :string, enum: ["public", "private"]},
              token_prefix: %Schema{type: :string},
              expires_at: %Schema{type: :string, format: :"date-time", nullable: true}
            }
          }
        }
      }
    },
    example: %{
      "data" => %{
        "account" => %{
          "id" => "3f2a9d1e-6b4c-4f0e-9a51-2d7c8e1b0a44",
          "name" => "Acme Corp",
          "slug" => "acme-corp"
        },
        "user" => %{"id" => "9b1e7c2d-0f3a-4e5b-8c6d-1a2b3c4d5e6f", "email" => "user@example.com"},
        "role" => "owner",
        "api_key" => %{
          "id" => "c0ffee00-1234-4abc-9def-0123456789ab",
          "name" => "Production worker",
          "type" => "private",
          "token_prefix" => "sk_AbCdEfGhI",
          "expires_at" => nil
        }
      }
    }
  })
end
