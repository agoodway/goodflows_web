defmodule GoodFlowsWeb.Schemas.ReviewPolicyDocument do
  @moduledoc "OpenAPI schema for a `review-policy/1` document."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @outcome %Schema{type: :string, enum: ~w(needs_review blocked ignore)}
  @review %Schema{type: :string, enum: ~w(needs_review ignore)}

  OpenApiSpex.schema(%{
    title: "ReviewPolicyDocument",
    description:
      "Every section and key except `format` may be omitted and takes its version 0 " <>
        "value. Unknown keys and nulls are `422`.",
    type: :object,
    additionalProperties: false,
    required: [:format],
    properties: %{
      format: %Schema{type: :string, enum: ["review-policy/1"]},
      scenarios: %Schema{
        type: :object,
        additionalProperties: false,
        properties: %{
          require_approved_intent: %Schema{type: :boolean},
          should_failures: @review,
          spec_gaps: @review,
          approver: %Schema{type: :string, enum: ~w(any other_member admin)},
          diff_only: %Schema{
            type: :string,
            enum: ~w(needs_review weakening ignore),
            description:
              "With `require_approved_intent` true, how a change request with only a diff " <>
                "set is reviewed: `needs_review` on every head, `weakening` only when the " <>
                "diff set removes or demotes a Must of its baseline, or `ignore`"
          }
        }
      },
      evidence: %Schema{
        type: :object,
        additionalProperties: false,
        properties: %{
          required_workflows: %Schema{type: :array, maxItems: 32, items: %Schema{type: :string}},
          ignore_paths: %Schema{type: :array, maxItems: 100, items: %Schema{type: :string}}
        }
      },
      claims: %Schema{
        type: :object,
        additionalProperties: false,
        properties: %{
          one_way_door: @outcome,
          min_proof_level: %Schema{type: :string, enum: ~w(stated pointed walked ran)},
          open_items: @outcome
        }
      },
      paths: %Schema{
        type: :array,
        maxItems: 100,
        description:
          "`**` matches whole segments, `*` within a segment, `?` one character; " <>
            "`[ ] { } \\` are rejected",
        items: %Schema{
          type: :object,
          additionalProperties: false,
          properties: %{
            glob: %Schema{type: :string, minLength: 1, maxLength: 1024},
            outcome: @outcome
          }
        }
      },
      size: %Schema{
        type: :object,
        additionalProperties: false,
        properties: %{
          max_changed_files: %Schema{type: :integer, minimum: 1},
          max_changed_lines: %Schema{type: :integer, minimum: 1}
        }
      },
      coverage: %Schema{
        type: :object,
        additionalProperties: false,
        properties: %{unmapped_areas: @outcome, undriven_features: @outcome}
      },
      merge: %Schema{
        type: :object,
        additionalProperties: false,
        properties: %{
          lease_ttl: %Schema{type: :string, description: "`<n>s`, `<n>m` or `<n>h`, 1m to 1h"},
          regrade_merge_result: %Schema{type: :boolean}
        }
      }
    }
  })
end
