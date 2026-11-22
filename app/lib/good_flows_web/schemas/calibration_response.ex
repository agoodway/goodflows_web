defmodule GoodFlowsWeb.Schemas.CalibrationResponse do
  @moduledoc "OpenAPI schema for the calibration report."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.CalibrationLanes
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CalibrationResponse",
    description:
      "Computed on read for change requests whose `merged_at` is in `[from, to)`, " <>
        "with every defect attributed to them whenever it was recorded.",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :object,
        required: [
          :from,
          :to,
          :lanes,
          :policy_versions,
          :rules,
          :gaps,
          :globs,
          :unmatched_defect_count,
          :defects,
          :defects_truncated,
          :unattributed_defect_count
        ],
        properties: %{
          from: %Schema{type: :string, format: :"date-time"},
          to: %Schema{type: :string, format: :"date-time"},
          lanes: CalibrationLanes,
          policy_versions: %Schema{
            type: :array,
            description: "Per `merge.policy_version`, ascending",
            items: %Schema{
              type: :object,
              required: [:version, :lanes],
              properties: %{
                version: %Schema{type: :integer, minimum: 0},
                lanes: CalibrationLanes
              }
            }
          },
          rules: %Schema{
            type: :array,
            description: "Per `rule` in the merged change requests' `merge.reasons`",
            items: %Schema{
              type: :object,
              required: [:rule, :fired_count, :fired_with_defects_count],
              properties: %{
                rule: %Schema{type: :string},
                fired_count: %Schema{type: :integer, minimum: 0},
                fired_with_defects_count: %Schema{type: :integer, minimum: 0}
              }
            }
          },
          gaps: %Schema{
            type: :array,
            description: "Numbers of defective change requests merged with no reasons",
            items: %Schema{type: :integer}
          },
          globs: %Schema{
            type: :array,
            description:
              "Per `paths` glob of the policy versions in the window: defects whose files " <>
                "match it (a commit's `changed_files`, else the merged head's diff)",
            items: %Schema{
              type: :object,
              required: [:glob, :defect_count],
              properties: %{
                glob: %Schema{type: :string},
                defect_count: %Schema{type: :integer, minimum: 0}
              }
            }
          },
          unmatched_defect_count: %Schema{
            type: :integer,
            minimum: 0,
            description: "Defects with no file matching any glob"
          },
          defects: %Schema{
            type: :array,
            description:
              "The defects counted above, newest `recorded_at` first, at most 500, each with " <>
                "its change request's lane, `merge.policy_version` and `merge.reasons` rules, " <>
                "and the globs its files match",
            items: %Schema{
              type: :object,
              required: [
                :id,
                :change_request,
                :commit,
                :attribution,
                :severity,
                :ticket,
                :recorded_at,
                :lane,
                :policy_version,
                :rules,
                :globs
              ],
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                change_request: %Schema{type: :integer},
                commit: %Schema{type: :string, nullable: true},
                attribution: %Schema{type: :string, enum: ~w(change_request commit)},
                severity: %Schema{
                  type: :string,
                  nullable: true,
                  enum: ~w(low medium high critical)
                },
                ticket: %Schema{
                  type: :string,
                  nullable: true,
                  description: "Null for public keys"
                },
                recorded_at: %Schema{type: :string, format: :"date-time"},
                lane: %Schema{type: :string, enum: ~w(auto reviewed bypass)},
                policy_version: %Schema{type: :integer, minimum: 0},
                rules: %Schema{type: :array, items: %Schema{type: :string}},
                globs: %Schema{type: :array, items: %Schema{type: :string}}
              }
            }
          },
          defects_truncated: %Schema{
            type: :boolean,
            description: "True when more defects exist than `defects` lists; counts cover all"
          },
          unattributed_defect_count: %Schema{
            type: :integer,
            minimum: 0,
            description:
              "Unattributed defects whose `recorded_at` (not a merge time) is in `[from, to)`; " <>
                "they count in no lane, rule or glob"
          }
        }
      }
    }
  })
end
