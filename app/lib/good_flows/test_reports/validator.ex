defmodule GoodFlows.TestReports.Validator do
  @moduledoc """
  Validates an `exunit-timings` test report document against the wire
  contract (design D1 of the `store-test-timings` change).

  Validation runs in two passes. The structural pass checks every field's
  presence, type and bounds and rejects unknown fields at every level,
  including a body `project` or `account_id`. Only a structurally valid
  document reaches the consistency pass, which checks record identities,
  record ordering, execution start/finish pairing, partition agreement and
  the final summary against the finished events.

  The path slug of the request is not part of the document and is not
  checked here. Measured durations are never compared with event receipt
  offsets, and no value is rewritten: the accepted document is the
  normalized body.
  """

  alias GoodFlows.TestReports.{Completion, Consistency, Document, Shape}

  @max_records 100_000

  @outcomes ~w(passed failed skipped excluded invalid)
  @job_statuses ~w(passed failed timed_out cancelled skipped unknown)
  @filter_tags ~w(chrome goodaudit_integration athena_preview chromic_teardown qpdf)

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @partition ~r/\A[A-Za-z0-9._-]+\z/
  @commit ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/

  @typedoc "Validation errors keyed by rendered JSON path."
  @type errors :: %{String.t() => [String.t()]}

  @doc "Maximum number of records in one report."
  @spec max_records() :: pos_integer()
  def max_records, do: @max_records

  @doc "Test and module outcome vocabulary."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @doc "Accepted `job_status` values."
  @spec job_statuses() :: [String.t()]
  def job_statuses, do: @job_statuses

  @doc "Accepted filter tags."
  @spec filter_tags() :: [String.t()]
  def filter_tags, do: @filter_tags

  @doc """
  Validates a decoded document (the result of `Document.decode/1`, or plain
  maps). Returns the normalized document with its derived completion
  status, or errors keyed by JSON path.
  """
  @spec validate(term()) ::
          {:ok, map(), Completion.status()} | {:error, {:invalid, errors()}}
  def validate(document) do
    with {:ok, document} <- normalize(document),
         [] <- Shape.check(document, envelope_spec(), []),
         [] <- Consistency.check(document) do
      {:ok, document, Completion.status(document)}
    else
      errors when is_list(errors) -> {:error, {:invalid, render(errors)}}
      {:error, {:invalid, _}} = error -> error
    end
  end

  defp normalize(document) do
    case Document.normalize(document) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, {:invalid, render([{[], "must be a JSON object"}])}}
      {:error, errors} -> {:error, {:invalid, render(errors)}}
    end
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

  ## Specs

  defp name, do: {:string, min: 1, max: 64, no_control: true}
  defp text, do: {:string, min: 1, max: 4096}
  defp identifier, do: {:string, min: 1, max: 128, format: @identifier}
  defp nonneg, do: {:int, 0}
  defp positive, do: {:int, 1}
  defp counts, do: {:fun, &counts_errors/2, :counts}
  defp relative_file, do: {:nullable, {:fun, &file_errors/2, :relative_file}}

  @doc "Record `event` values, in contract order."
  @spec events() :: [String.t()]
  def events do
    ~w(suite_started test_started test_finished module_started module_finished suite_finished
       max_failures_reached interrupted)
  end

  @doc """
  The `GoodFlows.TestReports.Shape` spec of the envelope. `report.records`
  is the custom check `:records`; each record follows `event_spec/1`.
  """
  @spec envelope_spec() :: Shape.spec()
  def envelope_spec do
    {:object,
     %{
       "format" => {:enum, ["exunit-timings"]},
       "workflow_run_id" => {:string, format: @uuid},
       "workflow" => name(),
       "environment" => {:nullable, name()},
       "job" => name(),
       "job_status" => {:enum, @job_statuses},
       "source" =>
         {:object,
          %{
            "commit" => {:nullable, {:string, format: @commit}},
            "branch" => {:nullable, {:string, min: 1, max: 256}},
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

  defp partition, do: {:string, min: 1, max: 64, format: @partition}

  defp common_fields do
    %{
      "event" => {:string, []},
      "run_id" => identifier(),
      "report_id" => identifier(),
      "received_offset_us" => nonneg()
    }
  end

  defp test_started_fields do
    %{
      "module" => text(),
      "name" => text(),
      "description" => {:nullable, text()},
      "file" => relative_file(),
      "line" => {:nullable, positive()},
      "describe" => {:nullable, text()},
      "async" => {:nullable, :boolean},
      "parameter_id" => {:nullable, positive()},
      "execution_id" => positive(),
      "started_offset_us" => nonneg()
    }
  end

  defp module_started_fields do
    %{
      "module" => text(),
      "file" => relative_file(),
      "async" => {:nullable, :boolean},
      "parameter_id" => {:nullable, positive()},
      "execution_id" => positive(),
      "started_offset_us" => nonneg(),
      "setup_all" => :boolean
    }
  end

  @doc "Fields shared by a start event and its finish event, by finish event type."
  @spec start_fields(String.t()) :: [String.t()]
  def start_fields("test_finished"), do: Map.keys(test_started_fields())
  def start_fields("module_finished"), do: Map.keys(module_started_fields())

  @doc "The `GoodFlows.TestReports.Shape` spec of one record with `event`."
  @spec event_spec(String.t()) :: Shape.spec()
  def event_spec(event) do
    case event_fields(event) do
      nil -> raise ArgumentError, "unknown test report event"
      fields -> {:object, Map.merge(common_fields(), fields)}
    end
  end

  defp event_fields("suite_started") do
    filter = {:object, %{"tag" => {:enum, @filter_tags}, "value" => :boolean}}

    %{
      "format" => {:enum, ["exunit-timings"]},
      "started_at" => {:fun, &started_at_errors/2, :timestamp},
      "partition" => {:nullable, partition()},
      "partition_count" => {:nullable, positive()},
      "seed" => {:nullable, {:int, nil}},
      "max_cases" => positive(),
      "schedulers" => positive(),
      "elixir_version" => {:string, min: 1, max: 128},
      "otp_release" => {:string, min: 1, max: 128},
      "filters" => {:object, %{"include" => {:list, filter}, "exclude" => {:list, filter}}}
    }
  end

  defp event_fields("test_started"), do: test_started_fields()

  defp event_fields("test_finished") do
    Map.merge(test_started_fields(), %{
      "duration_us" => {:nullable, nonneg()},
      "outcome" => {:enum, @outcomes}
    })
  end

  defp event_fields("module_started"), do: module_started_fields()

  defp event_fields("module_finished") do
    Map.merge(module_started_fields(), %{
      "observed_duration_us" => {:nullable, nonneg()},
      "outcome" => {:enum, @outcomes},
      "counts" => counts()
    })
  end

  defp event_fields("suite_finished") do
    %{
      "aborted" => :boolean,
      "unfinished_tests" => nonneg(),
      "unfinished_modules" => nonneg(),
      "counts" => counts(),
      "files" => {:list, {:object, file_fields()}},
      "times_us" =>
        {:object,
         %{
           "run" => nonneg(),
           "async" => {:nullable, nonneg()},
           "sync" => nonneg(),
           "load" => {:nullable, nonneg()},
           "total" => nonneg()
         }}
    }
  end

  defp event_fields(event) when event in ["max_failures_reached", "interrupted"], do: %{}
  defp event_fields(_event), do: nil

  defp bucket_fields do
    %{
      "test_count" => nonneg(),
      "module_count" => nonneg(),
      "counts" => counts(),
      "test_duration_us" => nonneg(),
      "observed_module_duration_us" => nonneg()
    }
  end

  defp file_fields do
    bucket = {:object, bucket_fields()}

    Map.merge(bucket_fields(), %{
      "file" => relative_file(),
      "async" => bucket,
      "sync" => bucket,
      "unknown" => bucket
    })
  end

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

  defp file_errors(file, path) when is_binary(file) do
    segments = String.split(file, ["/", "\\"])

    cond do
      file == "" -> [{path, "can't be blank"}]
      byte_size(file) > 4096 -> [{path, "is too long"}]
      absolute?(file) or ".." in segments -> [{path, "must be a relative path"}]
      true -> []
    end
  end

  defp file_errors(_file, path), do: [{path, "must be a string"}]

  defp absolute?(file) do
    String.starts_with?(file, ["/", "\\", "~"]) or Regex.match?(~r/\A[A-Za-z]:/, file)
  end

  defp started_at_errors(value, path) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> []
      _other -> [{path, "must be a UTC ISO 8601 timestamp"}]
    end
  end

  defp started_at_errors(value, path) when is_binary(value), do: [{path, "is too long"}]
  defp started_at_errors(_value, path), do: [{path, "must be a string"}]
end
