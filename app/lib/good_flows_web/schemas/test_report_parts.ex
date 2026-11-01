defmodule GoodFlowsWeb.Schemas.TestReportParts do
  @moduledoc """
  Builds OpenAPI schemas for the test report upload from the validator's
  own shape specs (`GoodFlows.TestReports.Validator.envelope_spec/0` and
  `event_spec/1`), so the documented contract and the enforced contract
  cannot drift apart.

  String lengths in the contract are UTF-8 bytes; OpenAPI `minLength` and
  `maxLength` count characters, so they are exact only for ASCII.
  """

  alias GoodFlows.TestReports.{Document, Validator}
  alias OpenApiSpex.Schema

  @doc "Schema of the request body; `records` items reference `event_schema/0`."
  @spec envelope(module()) :: Schema.t()
  def envelope(event_schema), do: to_schema(Validator.envelope_spec(), event_schema)

  @doc "One `oneOf` branch per record `event`."
  @spec events() :: [Schema.t()]
  def events do
    for event <- Validator.events() do
      {:object, fields} = Validator.event_spec(event)
      schema = to_schema({:object, Map.put(fields, "event", {:enum, [event]})}, nil)
      %{schema | title: "TestReport_" <> Macro.camelize(event)}
    end
  end

  defp to_schema(:boolean, _events), do: %Schema{type: :boolean}

  defp to_schema({:int, min}, _events),
    do: %Schema{
      type: :integer,
      minimum: min || -Document.max_integer(),
      maximum: Document.max_integer()
    }

  defp to_schema({:enum, values}, _events), do: %Schema{type: :string, enum: values}

  defp to_schema({:string, opts}, _events) do
    %Schema{
      type: :string,
      minLength: opts[:min],
      maxLength: opts[:max],
      pattern: opts[:format] && pattern(opts[:format])
    }
  end

  defp to_schema({:nullable, spec}, events), do: %{to_schema(spec, events) | nullable: true}
  defp to_schema({:list, spec}, events), do: %Schema{type: :array, items: to_schema(spec, events)}

  defp to_schema({:object, fields}, events) do
    %Schema{
      type: :object,
      required: fields |> Map.keys() |> Enum.sort(),
      properties: Map.new(fields, fn {key, spec} -> {key, to_schema(spec, events)} end),
      additionalProperties: false
    }
  end

  defp to_schema({:fun, _fun, :counts}, _events) do
    %Schema{
      type: :object,
      description: "Outcome counts; omitted outcomes count as zero.",
      properties: Map.new(Validator.outcomes(), &{&1, %Schema{type: :integer, minimum: 0}}),
      additionalProperties: false
    }
  end

  defp to_schema({:fun, _fun, :relative_file}, _events) do
    %Schema{
      type: :string,
      minLength: 1,
      maxLength: 4096,
      description: "Relative source path; never absolute and never containing `..`."
    }
  end

  defp to_schema({:fun, _fun, :timestamp}, _events),
    do: %Schema{type: :string, format: :"date-time", description: "UTC ISO 8601 timestamp"}

  defp to_schema({:fun, _fun, :records}, events) do
    %Schema{
      type: :array,
      minItems: 1,
      maxItems: Validator.max_records(),
      items: events,
      description:
        "Producer events in original order. The first is the only `suite_started`; " <>
          "a `suite_finished`, if present, is the only one and the last."
    }
  end

  defp pattern(regex) do
    regex |> Regex.source() |> String.replace("\\A", "^") |> String.replace("\\z", "$")
  end
end
