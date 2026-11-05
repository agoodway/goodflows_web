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

  # The validator's `started_at` grammar (goodflows `valid_timestamp`),
  # except calendar validity, which a regular expression cannot express.
  @timestamp_pattern "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[Tt]" <>
                       "([01][0-9]|2[0-3]):[0-5][0-9]:([0-5][0-9]|60)" <>
                       "(\\.[0-9]+)?(Z|z|\\+00:00|-00:00)$"

  @doc "The OpenAPI `pattern` of `suite_started.started_at`."
  @spec timestamp_pattern() :: String.t()
  def timestamp_pattern, do: @timestamp_pattern

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

  defp to_schema({:list, spec, opts}, events) when is_list(opts),
    do: %{to_schema({:list, spec}, events) | maxItems: Keyword.fetch!(opts, :max)}

  defp to_schema({:object, fields}, events) do
    %Schema{
      type: :object,
      required:
        for({key, spec} <- fields, not match?({:optional, _}, spec), do: key) |> Enum.sort(),
      properties: Map.new(fields, fn {key, spec} -> {key, to_schema(spec, events)} end),
      additionalProperties: false
    }
  end

  defp to_schema({:optional, spec}, events), do: to_schema(spec, events)

  defp to_schema({:fun, _fun, :counts}, _events) do
    %Schema{
      type: :object,
      description: "Outcome counts; omitted outcomes count as zero.",
      properties: Map.new(Validator.outcomes(), &{&1, %Schema{type: :integer, minimum: 0}}),
      additionalProperties: false
    }
  end

  defp to_schema({:fun, _fun, :timestamp}, _events) do
    # No `format: date-time`: RFC 3339 tools reject spellings the contract
    # accepts (second 60, `-00:00`) and accept ones it rejects.
    %Schema{
      type: :string,
      maxLength: 64,
      pattern: @timestamp_pattern,
      description:
        "UTC timestamp of at most 64 bytes: `YYYY-MM-DD`, `T` or `t` (never a space), " <>
          "`HH:MM:SS` with seconds at most 60, an optional `.` followed by at least one " <>
          "digit, then `Z`, `z`, `+00:00` or `-00:00`. The pattern checks this grammar " <>
          "and the month, day, hour, minute and second ranges; whether the day exists in " <>
          "its month (so `2026-02-30` or `2025-02-29` is rejected) is checked by the " <>
          "server only, since a pattern cannot express it."
    }
  end

  defp to_schema({:fun, _fun, :meta}, _events) do
    %Schema{
      type: :object,
      maxProperties: Validator.max_meta_keys(),
      # OAS 3.0 ignores `nullable` on a schema without `type`, so each
      # branch allows `null` itself.
      additionalProperties: %Schema{
        anyOf: [
          %Schema{type: :boolean, nullable: true},
          %{to_schema({:int, nil}, nil) | nullable: true},
          %Schema{type: :string, maxLength: Validator.max_meta_string_bytes(), nullable: true}
        ]
      },
      description:
        "Optional, flat runner metadata. Keys follow the identifier grammar " <>
          "(1 to 128 bytes of `[A-Za-z0-9._-]`, starting with a letter or digit); " <>
          "values are null, booleans, integers or strings of at most 256 bytes. " <>
          "Stored as supplied."
    }
  end

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
