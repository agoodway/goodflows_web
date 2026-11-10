defmodule GoodFlowsWeb.Schemas.WorkflowRunParts do
  @moduledoc """
  Builds OpenAPI schemas for workflow-run documents from
  `GoodFlows.WorkflowRuns.Validator.document_spec/0`, so the documented
  contract and the enforced contract stay on the same field tables.

  String lengths in the contract are UTF-8 bytes. OpenAPI `minLength` and
  `maxLength` count characters, so they are exact only for ASCII. Optional
  keys use `{:omit, spec}` and stay out of `required`. Nullable keys are
  required and `nullable`.
  """

  alias GoodFlows.JsonDocument
  alias GoodFlows.TestReports.Validator, as: TestReportValidator
  alias GoodFlows.WorkflowRuns.Validator
  alias OpenApiSpex.Schema

  # Summaries copy document properties (string keys) into a new schema.
  # Dialyzer widens those structs past `Schema.t()`.
  @dialyzer {:nowarn_function, summary: 0, report_summary: 0}

  @started_at_pattern "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"

  @doc "The OpenAPI `pattern` of `started_at`."
  @spec started_at_pattern() :: String.t()
  def started_at_pattern, do: @started_at_pattern

  @doc "Schema of a run-history document, without a title."
  @spec document() :: Schema.t()
  def document, do: to_schema(Validator.document_spec())

  @doc """
  Schema of a stored document as shown. Every `command` and condition
  `text` is nullable, because a public key receives them as null.
  """
  @spec shown_document() :: Schema.t()
  def shown_document, do: Validator.document_spec() |> redactable() |> to_schema()

  @doc "A minimal document, used as the request example."
  @spec example() :: map()
  def example do
    %{
      "schema_version" => 1,
      "workflow" => "ci",
      "run_id" => "11111111-1111-4111-8111-111111111111",
      "started_at" => "2026-11-05T12:00:00Z",
      "outcome" => "passed",
      "duration_ms" => 0,
      "parallelism" => 1,
      "graph_sha256" => String.duplicate("ab", 32),
      "max_in_flight" => 0,
      "host" => %{"os" => "linux", "arch" => "x86_64", "logical_cpus" => 1},
      "results" => []
    }
  end

  @doc "One run summary. `environment` and `source` are null when omitted."
  @spec summary() :: Schema.t()
  def summary do
    props = document().properties

    %Schema{
      type: :object,
      additionalProperties: false,
      description:
        "Fields copied out of the document for comparison. `results` and " <>
          "`graph` are not included. `source.dirty` and `source.branch` are " <>
          "present only when the document included them.",
      required: ~w(
        id run_id workflow environment outcome started_at duration_ms parallelism
        max_in_flight graph_sha256 source ci host inserted_at
      ),
      properties: %{
        "id" => %Schema{type: :string, format: :uuid, description: "Stable server id"},
        "run_id" => props["run_id"],
        "workflow" => props["workflow"],
        "environment" => nullable(props["environment"], "Null when the document omitted it."),
        "outcome" => props["outcome"],
        "started_at" => props["started_at"],
        "duration_ms" => props["duration_ms"],
        "parallelism" => props["parallelism"],
        "max_in_flight" => props["max_in_flight"],
        "graph_sha256" => props["graph_sha256"],
        "source" =>
          nullable(
            props["source"],
            "Null when the document omitted `source`. `dirty` and `branch` are present " <>
              "only when they were stored."
          ),
        "ci" => nullable(props["ci"], "Null when the document omitted `ci`."),
        "host" => props["host"],
        "inserted_at" => %Schema{
          type: :string,
          format: :"date-time",
          description: "When the server stored the run"
        }
      }
    }
  end

  @doc "One linked test report, without its contents."
  @spec report_summary() :: Schema.t()
  def report_summary do
    %Schema{
      type: :object,
      additionalProperties: false,
      description:
        "A test report stored in the same account and project whose " <>
          "`workflow_run_id` equals this run. There is no foreign key; the " <>
          "report may have arrived first.",
      required: ~w(id job job_status suite_id report_id partition partition_count status),
      properties: %{
        "id" => %Schema{type: :string, format: :uuid},
        "job" => %Schema{type: :string},
        "job_status" => %Schema{type: :string, enum: TestReportValidator.job_statuses()},
        "suite_id" => %Schema{type: :string},
        "report_id" => %Schema{type: :string},
        "partition" => %Schema{type: :string, nullable: true},
        "partition_count" => %Schema{type: :integer, nullable: true},
        "status" => %Schema{type: :string, enum: ["complete", "incomplete"]}
      }
    }
  end

  defp redactable({:object, fields}),
    do: {:object, Map.new(fields, fn {key, spec} -> {key, redactable(key, spec)} end)}

  defp redactable({wrapper, spec}) when wrapper in [:omit, :nullable, :list],
    do: {wrapper, redactable(spec)}

  defp redactable({:list, spec, opts}), do: {:list, redactable(spec), opts}
  defp redactable(spec), do: spec

  defp redactable(key, {:nullable, _spec} = spec) when key in ~w(command text), do: spec
  defp redactable(key, spec) when key in ~w(command text), do: {:nullable, spec}
  defp redactable(_key, spec), do: redactable(spec)

  defp nullable(schema, note) do
    %{schema | nullable: true, description: join_description(schema.description, note)}
  end

  defp join_description(nil, note), do: note
  defp join_description(existing, note), do: existing <> " " <> note

  defp to_schema(:boolean), do: %Schema{type: :boolean}
  defp to_schema({:enum, values}), do: %Schema{type: :string, enum: values}
  defp to_schema({:nullable, spec}), do: %{to_schema(spec) | nullable: true}
  defp to_schema({:omit, spec}), do: to_schema(spec)
  defp to_schema({:list, spec}), do: %Schema{type: :array, items: to_schema(spec)}

  defp to_schema({:list, spec, opts}) do
    %{to_schema({:list, spec}) | minItems: opts[:min], maxItems: opts[:max]}
  end

  defp to_schema({:int, minimum}) do
    %Schema{type: :integer, minimum: minimum, maximum: JsonDocument.max_integer()}
  end

  defp to_schema({:string, opts}) do
    %{type: :string}
    |> maybe_put(:minLength, opts[:min])
    |> maybe_put(:maxLength, opts[:max])
    |> maybe_put(:pattern, opts[:format] && pattern(opts[:format]))
    |> maybe_put(:description, string_description(opts))
    |> then(&struct!(Schema, &1))
  end

  defp to_schema({:object, fields}) do
    %Schema{
      type: :object,
      required: required_keys(fields),
      properties: Map.new(fields, fn {key, spec} -> {key, to_schema(spec)} end),
      additionalProperties: false
    }
  end

  defp to_schema({:fun, _fun, :schema_version}) do
    %Schema{type: :integer, enum: [1], description: "Must be `1`."}
  end

  defp to_schema({:fun, _fun, :started_at}) do
    %Schema{
      type: :string,
      pattern: @started_at_pattern,
      description:
        "UTC time to the second, `YYYY-MM-DDTHH:MM:SSZ`. Offsets and fractional " <>
          "seconds are rejected."
    }
  end

  defp to_schema({:fun, _fun, :exit_code}) do
    %Schema{
      type: :integer,
      minimum: -2_147_483_648,
      maximum: 2_147_483_647,
      description: "Signed 32-bit exit code. Null on a workflow-call result."
    }
  end

  defp to_schema({:fun, _fun, :partition}) do
    %Schema{
      type: :object,
      additionalProperties: false,
      required: ~w(count index),
      description: "`index` is 1-based and at most `count`. `count` is at most 64.",
      properties: %{
        "index" => %Schema{type: :integer, minimum: 1, maximum: JsonDocument.max_integer()},
        "count" => %Schema{type: :integer, minimum: 1, maximum: Validator.max_partitions()}
      }
    }
  end

  defp to_schema({:fun, _fun, :partition_count}) do
    %Schema{type: :integer, minimum: 1, maximum: Validator.max_partitions()}
  end

  defp to_schema({:fun, _fun, :ci_url}) do
    %Schema{
      type: :string,
      maxLength: 2_048,
      description: "An absolute `https` URL with a host, at most 2,048 bytes."
    }
  end

  defp required_keys(fields) do
    fields
    |> Enum.reject(fn {_key, spec} -> match?({:omit, _spec}, spec) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp string_description(opts) do
    notes =
      Enum.reject(
        [
          opts[:max] && "at most #{opts[:max]} UTF-8 bytes",
          opts[:no_control] && "no control characters",
          opts[:non_blank] && "not only whitespace"
        ],
        &is_nil/1
      )

    case notes do
      [] ->
        nil

      notes ->
        Enum.join(notes, ", ") <>
          ". Byte limits are UTF-8 bytes; OpenAPI lengths count characters and match for ASCII."
    end
  end

  defp pattern(regex) do
    regex |> Regex.source() |> String.replace("\\A", "^") |> String.replace("\\z", "$")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
