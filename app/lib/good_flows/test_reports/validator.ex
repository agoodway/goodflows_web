defmodule GoodFlows.TestReports.Validator do
  @moduledoc """
  Validates a `test-timings/1` test report document against the contract
  specified in `openspec/specs/test-timing-contract/spec.md`.

  goodflows owns the contract. This module mirrors goodflows
  `src/reporting/contract.rs` (the per-event field tables, `check/2` and
  `valid_meta/1`) and `Validator::push` in `src/reporting/collect.rs`
  (through `GoodFlows.TestReports.Consistency`) at the goodflows change
  named by `contract_version/0`, and accepts exactly the documents goodflows
  collection accepts. The tables below map one-to-one onto that module's
  `COMMON`, `SUITE_STARTED`, `GROUP_STARTED` (+`GROUP_FINISHED_EXTRA`),
  `TEST_STARTED` (+`TEST_FINISHED_EXTRA`) and `SUITE_FINISHED`, so the next
  contract revision is a table diff on both sides.

  Validation runs in passes. First, on the decoded document before any
  other check (including duplicate keys, NULs and integer range), a present
  envelope `format`, or a first `suite_started` record's `format`, that is
  not `test-timings/1` is the only error reported (`format_rejection/1`).
  Then `GoodFlows.TestReports.Document.normalize/1` applies the encoding
  rules; its error paths are cut back to keys this contract defines, so a
  submitted key name never appears in an error (a value error anywhere
  under a `meta` is `has an invalid value` on that `meta`). The structural pass checks every field's presence,
  type and bounds and rejects unknown fields at every level, including a
  body `project` or `account_id`. Only a structurally valid document
  reaches the consistency pass, which checks record identities, record
  ordering, partition agreement, start/finish pairing and the unfinished
  counts.

  The path slug of the request is not part of the document and is not
  checked here. Durations, counts and file paths are stored as supplied:
  they are never compared with each other or with event receipt offsets,
  and no value is rewritten. The accepted document is the normalized body.
  """

  alias GoodFlows.TestReports.{Completion, Consistency, Document, Shape}

  @contract_version "2026-11-04-generalize-test-timings"
  @format "test-timings/1"
  @retired_format "exunit-timings"

  @max_records 100_000
  @max_filters 256
  @max_path_entries 32
  @max_meta_keys 32
  @max_meta_string_bytes 256

  @outcomes ~w(passed failed skipped errored)
  @job_statuses ~w(passed failed timed_out cancelled skipped unknown)

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @partition ~r/\A[A-Za-z0-9._-]+\z/
  @commit ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/
  @timestamp_tail ~r/\A(?:\.[0-9]+)?(?:Z|z|\+00:00|-00:00)\z/

  @typedoc "Validation errors keyed by rendered JSON path."
  @type errors :: %{String.t() => [String.t()]}

  @doc """
  The goodflows change whose `src/reporting/contract.rs` this module
  mirrors.
  """
  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @doc "The only accepted `format`, in the envelope and in `suite_started`."
  @spec format() :: String.t()
  def format, do: @format

  @doc "Maximum number of records in one report."
  @spec max_records() :: pos_integer()
  def max_records, do: @max_records

  @doc "Maximum number of entries in each `suite_started` filter list."
  @spec max_filters() :: pos_integer()
  def max_filters, do: @max_filters

  @doc "Maximum number of keys in a record's `meta`."
  @spec max_meta_keys() :: pos_integer()
  def max_meta_keys, do: @max_meta_keys

  @doc "Maximum UTF-8 bytes of a `meta` string value."
  @spec max_meta_string_bytes() :: pos_integer()
  def max_meta_string_bytes, do: @max_meta_string_bytes

  @doc "Test and group outcome vocabulary, and the only `counts` keys."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "Accepted `job_status` values."
  @spec job_statuses() :: [String.t()]
  def job_statuses, do: @job_statuses

  @doc """
  Validates a decoded document (the result of `Document.decode/1`, or plain
  maps). Returns the normalized document with its derived completion
  status, or errors keyed by JSON path.
  """
  @spec validate(term()) ::
          {:ok, map(), Completion.status()} | {:error, {:invalid, errors()}}
  def validate(document) do
    case format_rejection(document) do
      nil -> validate_contract(document)
      {path, _declared} -> {:error, {:invalid, render([{path, "is invalid"}])}}
    end
  end

  defp validate_contract(document) do
    with {:ok, document} <- normalize(document),
         [] <- Shape.check(document, envelope_spec(), []),
         [] <- Consistency.check(document) do
      {:ok, document, Completion.status(document)}
    else
      errors when is_list(errors) -> {:error, {:invalid, render(errors)}}
      {:error, {:invalid, _}} = error -> error
    end
  end

  @doc """
  The wrong `format` that makes `validate/1` report a single error, read
  from the decoded document before normalization (`Jason.OrderedObject`s or
  plain maps; with a duplicate key, its first value), or `nil`.

  Returns `{path, declared}`: `path` is `["format"]` when the envelope
  `format` is present and is not `test-timings/1`, otherwise
  `["report", "records", 0, "format"]` when the first record's `event` is
  `suite_started` and its `format` is present and is not `test-timings/1`.
  `declared` is `:retired` for `exunit-timings` and `:other` for any other
  value, so callers can tell the two apart without handling the submitted
  value. Like goodflows, a first record that is not `suite_started` is an
  ordering error and its `format` is not read; a missing `format` is left to
  the structural pass (`is required`), including a missing envelope
  `format` beside a wrong record `format`, which reports only the record.
  """
  @spec format_rejection(term()) :: {Document.path(), :retired | :other} | nil
  def format_rejection(document) do
    case field(document, "format") do
      {:ok, format} when format != @format -> {["format"], declared(format)}
      _absent_or_current -> record_format_rejection(document)
    end
  end

  defp record_format_rejection(document) do
    with {:ok, report} <- field(document, "report"),
         {:ok, [first | _]} <- field(report, "records"),
         {:ok, "suite_started"} <- field(first, "event"),
         {:ok, format} when format != @format <- field(first, "format") do
      {["report", "records", 0, "format"], declared(format)}
    else
      _other -> nil
    end
  end

  defp declared(@retired_format), do: :retired
  defp declared(_format), do: :other

  defp field(%Jason.OrderedObject{values: pairs}, key) do
    case List.keyfind(pairs, key, 0) do
      {^key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp field(map, key) when is_map(map) and not is_struct(map), do: Map.fetch(map, key)
  defp field(_value, _key), do: :error

  defp normalize(document) do
    case Document.normalize(document) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error, {:invalid, render([{[], "must be a JSON object"}])}}

      {:error, errors} ->
        spec = envelope_spec()
        record = record_union_spec()
        {:error, {:invalid, render(Enum.map(errors, &contract_error(&1, spec, record)))}}
    end
  end

  # `Document` reports a value error on the value's own path, which can run
  # through submitted keys (an unknown key, or a `meta` key). The path is
  # kept only while each key is one the enclosing spec defines; it stops
  # before the first other key or index, so the error lands on the
  # enclosing object. Any error inside a `meta` (a NUL string, an
  # out-of-range integer, or anything nested in a structured value) is
  # `has an invalid value` on that `meta`, like the structural check.
  defp contract_error({path, message}, spec, record) do
    case contract_path(path, spec, record, []) do
      {:meta_value, meta} -> {meta, "has an invalid value"}
      {:path, kept} -> {kept, message}
    end
  end

  defp contract_path([], _spec, _record, kept), do: {:path, Enum.reverse(kept)}

  defp contract_path(path, {wrapper, spec}, record, kept) when wrapper in [:nullable, :optional],
    do: contract_path(path, spec, record, kept)

  defp contract_path([key | rest], {:object, fields}, record, kept) when is_binary(key) do
    case Map.fetch(fields, key) do
      {:ok, spec} -> contract_path(rest, spec, record, [key | kept])
      :error -> {:path, Enum.reverse(kept)}
    end
  end

  defp contract_path([index | rest], {:list, spec}, record, kept) when is_integer(index),
    do: contract_path(rest, spec, record, [index | kept])

  defp contract_path([index | rest], {:list, spec, _opts}, record, kept) when is_integer(index),
    do: contract_path(rest, spec, record, [index | kept])

  defp contract_path([index | rest], {:fun, _fun, :records}, record, kept)
       when is_integer(index),
       do: contract_path(rest, record, record, [index | kept])

  defp contract_path([key | rest], {:fun, _fun, :counts}, record, kept) when key in @outcomes,
    do: contract_path(rest, nonneg(), record, [key | kept])

  defp contract_path([_key | _rest], {:fun, _fun, :meta}, _record, kept),
    do: {:meta_value, Enum.reverse(kept)}

  defp contract_path(_path, _spec, _record, kept), do: {:path, Enum.reverse(kept)}

  # Every key any record may have, so a path into a record keeps the
  # contract keys whatever the record's `event`.
  defp record_union_spec do
    {:object, Enum.reduce(events(), common_fields(), &Map.merge(&2, event_fields(&1)))}
  end

  @max_rendered_errors 50

  # `errors` arrive in document order, so the first 50 are kept.
  defp render(errors) do
    errors
    |> Enum.take(@max_rendered_errors)
    |> Enum.reduce(%{}, fn {path, message}, acc ->
      Map.update(acc, Document.render_path(path), [message], &Enum.uniq(&1 ++ [message]))
    end)
  end

  ## Specs (contract.rs field types)

  defp name, do: {:string, min: 1, max: 64, no_control: true}
  # Text / OptText
  defp text, do: {:string, min: 1, max: 4096}
  # Identifier
  defp identifier, do: {:string, min: 1, max: 128, format: @identifier}
  # UInt
  defp nonneg, do: {:int, 0}
  # ExecutionId; Line and PartitionCount are its nullable form
  defp positive, do: {:int, 1}
  defp counts, do: {:fun, &counts_errors/2, :counts}
  defp outcome, do: {:enum, @outcomes}
  defp partition, do: {:string, min: 1, max: 64, format: @partition}
  defp meta, do: {:optional, {:fun, &meta_errors/2, :meta}}

  @doc "Record `event` values, in contract order."
  @spec events() :: [String.t()]
  def events do
    ~w(suite_started group_started group_finished test_started test_finished suite_finished
       interrupted max_failures_reached)
  end

  @doc """
  The `GoodFlows.TestReports.Shape` spec of the envelope. `report.records`
  is the custom check `:records`; each record follows `event_spec/1`.
  """
  @spec envelope_spec() :: Shape.spec()
  def envelope_spec do
    {:object,
     %{
       "format" => {:enum, [@format]},
       "workflow_run_id" => {:string, format: @uuid},
       "workflow" => name(),
       "environment" => {:nullable, name()},
       "job" => name(),
       "job_status" => {:enum, @job_statuses},
       "source" =>
         {:object,
          %{
            "commit" => {:nullable, {:string, format: @commit}},
            "branch" => {:nullable, {:string, min: 1, max: 256, no_control: true}},
            "dirty" => {:nullable, :boolean}
          }},
       "report" =>
         {:object,
          %{
            "suite_id" => identifier(),
            "report_id" => identifier(),
            "partition" => {:nullable, partition()},
            "partition_count" => {:nullable, positive()},
            "truncated" => :boolean,
            "records" => {:fun, &records_errors/2, :records}
          }}
     }}
  end

  # COMMON, plus `event` and the optional META.
  defp common_fields do
    %{
      "event" => {:string, []},
      "suite_id" => identifier(),
      "report_id" => identifier(),
      "received_offset_us" => nonneg(),
      "meta" => meta()
    }
  end

  # SUITE_STARTED
  defp suite_started_fields do
    filter = {:list, {:object, %{"tag" => identifier(), "value" => :boolean}}, max: @max_filters}

    %{
      "format" => {:enum, [@format]},
      "started_at" => {:fun, &started_at_errors/2, :timestamp},
      "runner" =>
        {:object, %{"name" => identifier(), "version" => {:nullable, {:string, max: 128}}}},
      "partition" => {:nullable, partition()},
      "partition_count" => {:nullable, positive()},
      "seed" => {:nullable, {:int, nil}},
      "filters" => {:nullable, {:object, %{"include" => filter, "exclude" => filter}}}
    }
  end

  # GROUP_STARTED
  defp group_started_fields do
    %{
      "group" => text(),
      "file" => {:nullable, text()},
      "execution_id" => positive(),
      "started_offset_us" => nonneg()
    }
  end

  # TEST_STARTED
  defp test_started_fields do
    %{
      "group" => text(),
      "path" => {:list, text(), max: @max_path_entries},
      "name" => text(),
      "file" => {:nullable, text()},
      "line" => {:nullable, positive()},
      "execution_id" => positive(),
      "started_offset_us" => nonneg()
    }
  end

  # SUITE_FINISHED
  defp suite_finished_fields do
    %{
      "aborted" => :boolean,
      "unfinished_tests" => nonneg(),
      "unfinished_groups" => nonneg(),
      "counts" => counts(),
      "duration_us" => {:nullable, nonneg()}
    }
  end

  @doc """
  Core keys a finished event repeats from its started event, by finish
  event type (contract.rs `Shape.base`: common keys and `meta` excluded).
  """
  @spec start_fields(String.t()) :: [String.t()]
  def start_fields("test_finished"), do: Map.keys(test_started_fields())
  def start_fields("group_finished"), do: Map.keys(group_started_fields())

  @doc "The `GoodFlows.TestReports.Shape` spec of one record with `event`."
  @spec event_spec(String.t()) :: Shape.spec()
  def event_spec(event) do
    case event_fields(event) do
      nil -> raise ArgumentError, "unknown test report event"
      fields -> {:object, Map.merge(common_fields(), fields)}
    end
  end

  defp event_fields("suite_started"), do: suite_started_fields()
  defp event_fields("group_started"), do: group_started_fields()

  # GROUP_STARTED + GROUP_FINISHED_EXTRA
  defp event_fields("group_finished") do
    Map.merge(group_started_fields(), %{
      "duration_us" => {:nullable, nonneg()},
      "outcome" => outcome(),
      "counts" => counts()
    })
  end

  defp event_fields("test_started"), do: test_started_fields()

  # TEST_STARTED + TEST_FINISHED_EXTRA
  defp event_fields("test_finished") do
    Map.merge(test_started_fields(), %{
      "duration_us" => {:nullable, nonneg()},
      "outcome" => outcome()
    })
  end

  defp event_fields("suite_finished"), do: suite_finished_fields()
  defp event_fields(event) when event in ["interrupted", "max_failures_reached"], do: %{}
  defp event_fields(_event), do: nil

  ## Custom checks (paths are reversed)

  defp records_errors(records, path) when is_list(records) do
    cond do
      records == [] -> [{path, "must not be empty"}]
      length(records) > @max_records -> [{path, "must not have more than 100000 records"}]
      true -> records |> Enum.with_index() |> Enum.reduce([], &record_errors(&1, path, &2))
    end
  end

  defp records_errors(_records, path), do: [{path, "must be an array"}]

  defp record_errors({record, index}, path, errors) when is_map(record) do
    path = [index | path]

    case event_fields(Map.get(record, "event")) do
      nil ->
        [{["event" | path], "is invalid"} | errors]

      _fields ->
        Shape.check_into(record, event_spec(record["event"]), path, errors)
    end
  end

  defp record_errors({_record, index}, path, errors),
    do: [{[index | path], "must be an object"} | errors]

  defp counts_errors(counts, path) when is_map(counts) do
    fields = Map.new(@outcomes, &{&1, nonneg()})

    counts
    |> Enum.reduce([], fn {key, value}, errors ->
      if Map.has_key?(fields, key),
        do: Shape.check_into(value, nonneg(), [key | path], errors),
        else: errors
    end)
    |> then(&Shape.unknown_errors(counts, fields, path, &1))
  end

  defp counts_errors(_counts, path), do: [{path, "must be an object"}]

  # contract.rs `valid_meta`. Every fault is reported on `meta` itself:
  # its keys are arbitrary submitted text, so neither an error path nor a
  # message may name one.
  defp meta_errors(meta, path) when map_size(meta) > @max_meta_keys,
    do: [{path, "must not have more than #{@max_meta_keys} keys"}]

  # Prepended like every other check: the key error comes out first.
  defp meta_errors(meta, path) when is_map(meta) do
    errors =
      if Enum.all?(Map.keys(meta), &identifier?/1),
        do: [],
        else: [{path, "has an invalid key"}]

    if Enum.all?(Map.values(meta), &meta_value?/1),
      do: errors,
      else: [{path, "has an invalid value"} | errors]
  end

  defp meta_errors(_meta, path), do: [{path, "must be an object"}]

  defp identifier?(key),
    do: is_binary(key) and byte_size(key) <= 128 and Regex.match?(@identifier, key)

  defp meta_value?(value) when is_nil(value) or is_boolean(value), do: true
  # Integer magnitude is enforced by `Document.normalize/1` before this
  # pass; `normalize/1` above reports it on `meta` as `has an invalid value`.
  defp meta_value?(value) when is_integer(value), do: true
  defp meta_value?(value) when is_binary(value), do: byte_size(value) <= @max_meta_string_bytes
  defp meta_value?(_value), do: false

  # contract.rs `Timestamp` and `valid_timestamp`. `::4` would be four bits,
  # so the segments are byte-sized binaries.
  defp started_at_errors(value, path) when is_binary(value) and byte_size(value) > 64,
    do: [{path, "is too long"}]

  defp started_at_errors(value, path) when is_binary(value) do
    if valid_timestamp?(value), do: [], else: [{path, "must be a UTC ISO 8601 timestamp"}]
  end

  defp started_at_errors(_value, path), do: [{path, "must be a string"}]

  defp valid_timestamp?(
         <<year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2), t,
           hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2),
           rest::binary>>
       )
       when t in [?T, ?t] do
    case digits([year, month, day, hour, minute, second]) do
      [y, m, d, h, mi, s] ->
        Calendar.ISO.valid_date?(y, m, d) and h <= 23 and mi <= 59 and s <= 60 and
          Regex.match?(@timestamp_tail, rest)

      :error ->
        false
    end
  end

  defp valid_timestamp?(_value), do: false

  # Every part as an integer, or `:error` unless each is all ASCII digits.
  defp digits(parts) do
    if Enum.all?(parts, &Regex.match?(~r/\A[0-9]+\z/, &1)),
      do: Enum.map(parts, &String.to_integer/1),
      else: :error
  end
end
