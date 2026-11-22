defmodule GoodFlowsWeb.Schemas.Verdict do
  @moduledoc "OpenAPI schema for a change request verdict."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.VerdictReason
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Verdict",
    description: "Act on a verdict only while its `head` and `policy_version` are still current.",
    type: :object,
    required: [:state, :head, :policy_version, :reasons, :inputs, :review, :computed_at],
    properties: %{
      state: %Schema{type: :string, enum: ~w(pending blocked needs_review mergeable)},
      head: %Schema{type: :string, nullable: true},
      policy_version: %Schema{type: :integer, minimum: 0},
      reasons: %Schema{type: :array, items: VerdictReason},
      inputs: %Schema{type: :object, description: "Digests of the inputs"},
      scenarios: %Schema{
        type: :object,
        description:
          "Per set (`intent`, `diff`, null when absent): `version`, `digest`, `approved`, " <>
            "`graded`, and per scenario `id`, `priority`, `result` and the `run_id` it came " <>
            "from. The diff set also has `accepted` (its digest's latest decision is " <>
            "`approve`) and `baseline_version` (the newest accepted diff version, else 1)",
        properties: %{
          intent: %Schema{type: :object, nullable: true},
          diff: %Schema{type: :object, nullable: true}
        }
      },
      coverage: %Schema{
        type: :object,
        description:
          "Feature index `version`, `unmapped_areas` (changed paths) and mapped `features` " <>
            "(`id`, `driven`). Public keys see `unmapped_areas` and feature `id` as null.",
        properties: %{
          version: %Schema{type: :integer, nullable: true},
          unmapped_areas: %Schema{type: :array, items: %Schema{type: :string}, nullable: true},
          features: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, nullable: true},
                driven: %Schema{type: :boolean}
              }
            }
          }
        }
      },
      counted_runs: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Verify run IDs that counted for this verdict"
      },
      review: %Schema{
        type: :object,
        description:
          "The number of review packet `items` at the head and how many are `cleared` " <>
            "(a current `approve` or `choose` answer at the head). A `scenario_set_approval` item " <>
            "is counted in `items` but never in `cleared`: the set's approval removes it.",
        properties: %{items: %Schema{type: :integer}, cleared: %Schema{type: :integer}}
      },
      computed_at: %Schema{type: :string, format: :"date-time"}
    }
  })
end
