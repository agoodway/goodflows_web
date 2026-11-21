defmodule GoodFlowsWeb.Schemas.VerifyRunRequest do
  @moduledoc "OpenAPI schema: A `verify-run/1` document."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "VerifyRunRequest",
    description: "A `verify-run/1` document.",
    type: :object,
    required:
      ~w(format run_id started_at finished_at source scenario_set results features drift artifacts)a,
    additionalProperties: false,
    properties: %{
      format: %Schema{type: :string, enum: ["verify-run/1"]},
      run_id: %Schema{type: :string, format: :uuid},
      started_at: %Schema{type: :string, format: :"date-time"},
      finished_at: %Schema{type: :string, format: :"date-time"},
      source: %Schema{
        type: :object,
        required: [:commit, :branch, :dirty, :changed_files],
        properties: %{
          commit: %Schema{type: :string, pattern: "^([0-9a-f]{40}|[0-9a-f]{64})$"},
          branch: %Schema{type: :string, nullable: true},
          dirty: %Schema{type: :boolean},
          changed_files: %Schema{type: :array, items: %Schema{type: :string}, maxItems: 10_000}
        }
      },
      scenario_set: %Schema{
        type: :object,
        required: [:digest, :source],
        properties: %{
          digest: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"},
          source: %Schema{type: :string, enum: ~w(intent diff)}
        }
      },
      results: %Schema{
        type: :array,
        description: "Exactly one entry per scenario ID of the named set",
        items: %Schema{
          type: :object,
          required: [:id, :result, :failed_step, :reason, :evidence],
          properties: %{
            id: %Schema{oneOf: [%Schema{type: :integer, minimum: 1}, %Schema{type: :string}]},
            result: %Schema{type: :string, enum: ~w(passed failed not_run)},
            failed_step: %Schema{type: :string, nullable: true},
            reason: %Schema{type: :string, nullable: true},
            evidence: %Schema{type: :array, items: %Schema{type: :string}}
          }
        }
      },
      features: %Schema{
        type: :array,
        maxItems: 500,
        items: %Schema{
          type: :object,
          required: [:id, :entry_point, :result],
          properties: %{
            id: %Schema{type: :string},
            entry_point: %Schema{type: :string, nullable: true},
            result: %Schema{type: :string, enum: ~w(passed failed not_run)}
          }
        }
      },
      drift: %Schema{type: :array, items: %Schema{type: :string}, maxItems: 100},
      artifacts: %Schema{
        type: :array,
        maxItems: 200,
        items: %Schema{
          type: :object,
          required: [:id, :path, :content_type, :size, :sha256],
          properties: %{
            id: %Schema{type: :string},
            path: %Schema{type: :string},
            content_type: %Schema{type: :string},
            size: %Schema{type: :integer, minimum: 1, maximum: 52_428_800},
            sha256: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"}
          }
        }
      },
      merge_result: %Schema{
        type: :object,
        nullable: true,
        properties: %{base: %Schema{type: :string}, commit: %Schema{type: :string}}
      },
      links: %Schema{type: :object},
      workflow_run_id: %Schema{type: :string, format: :uuid, nullable: true}
    }
  })
end
