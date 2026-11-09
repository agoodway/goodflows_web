defmodule GoodFlows.WorkflowRuns.Validator do
  @moduledoc """
  Validates a goodflows run-history document at `schema_version` 1.

  The allowlist mirrors goodci `Record` (`src/history.rs`), including the
  workflow-call fields added without a version bump: `parent_run_id` and
  `caller_job` together or not at all, and a result's `workflow` with an
  optional `child_run_id`. Optional keys are omit-only. The required result
  keys `command`, `exit_code` and `error` are the only keys that may be
  null. Unknown fields stay unknown, including the upload envelope
  (`graph`, `ci`, `source.branch`).

  `validate/1` takes a decoded document (`JsonDocument.decode/1`, or a
  plain map). It normalizes first, so duplicate keys, NUL characters and
  integers outside `±(2^53 - 1)` are fixed errors whose paths are cut back
  to contract keys. The structural pass then checks presence, types and
  bounds. Outcome consistency runs only when every result status is valid.

  Instance caps live here: names are at most 64 bytes, `command` and
  `error` at most 1,024 bytes, `requested_jobs` and `commands` at most
  1,024 entries, and a partition count at most 64. Nesting deeper than
  `max_depth/0` (8) is rejected by the body plug's `JsonDocument.check_depth/2`
  before decode, not by this module. The same is true of the byte-size cap.

  The accepted document is the normalized body, returned with the column
  values copied out of it. `payload` is that document and `payload_digest`
  is `JsonDocument.digest/1` of it. `started_at` is parsed only after an
  exact `YYYY-MM-DDTHH:MM:SSZ` match, so offsets and fractional seconds are
  rejected rather than normalized. No submitted value is rewritten, and no
  error message contains one.
  """

  alias GoodFlows.JsonDocument
  alias GoodFlows.TestReports.Shape

  @max_depth 8
  @max_list_entries 1_024
  @max_text_bytes 1_024
  @max_name_bytes 64
  @max_partitions 64
  @max_rendered_errors 50
  @min_exit_code -2_147_483_648
  @max_exit_code 2_147_483_647

  @outcomes ~w(passed failed cancelled)
  @statuses ~w(passed failed skipped timed_out cancelled)
  @kinds ~w(condition command)

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @started_at ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @typedoc "Validation errors keyed by rendered JSON path."
  @type errors :: %{String.t() => [String.t()]}

  @typedoc """
  Values copied into `workflow_runs` columns. Absent omit-only fields are
  `nil`. `source_dirty` is `false` when the document sent `false`.
  """
  @type columns :: %{
          run_id: String.t(),
          workflow: String.t(),
          environment: String.t() | nil,
          outcome: String.t(),
          started_at: DateTime.t(),
          duration_ms: non_neg_integer(),
          parallelism: pos_integer(),
          max_in_flight: non_neg_integer(),
          graph_sha256: String.t(),
          source_commit: String.t() | nil,
          source_dirty: boolean() | nil,
          host: map()
        }

  @doc "Maximum object and array nesting of a workflow-run body."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc "Maximum entries in `requested_jobs` and in a result's `commands`."
  @spec max_list_entries() :: pos_integer()
  def max_list_entries, do: @max_list_entries

  @doc "Maximum UTF-8 bytes of a result `command` or `error`."
  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @doc "Maximum UTF-8 bytes of a name."
  @spec max_name_bytes() :: pos_integer()
  def max_name_bytes, do: @max_name_bytes

  @doc "Maximum `partition.count`, matching goodci `MAX_PARTITIONS`."
  @spec max_partitions() :: pos_integer()
  def max_partitions, do: @max_partitions

  @doc """
  The `GoodFlows.TestReports.Shape` spec of a run-history document.
  Optional keys use `{:omit, spec}` (absent or a value, never null).
  `command`, `exit_code` and `error` are nullable and required.
  """
  @spec document_spec() :: Shape.spec()
  def document_spec do
    {:object,
     %{
       "schema_version" => {:fun, &schema_version_errors/2, :schema_version},
       "workflow" => name(),
       "environment" => {:omit, name()},
       "requested_jobs" => {:omit, {:list, name(), min: 1, max: @max_list_entries}},
       "run_id" => uuid(),
       "parent_run_id" => {:omit, uuid()},
       "caller_job" => {:omit, name()},
       "started_at" => {:fun, &started_at_errors/2, :started_at},
       "outcome" => {:enum, @outcomes},
       "duration_ms" => nonneg(),
       "parallelism" => positive(),
       "graph_sha256" => {:string, format: @sha256},
       "max_in_flight" => nonneg(),
       "host" => host_spec(),
       "source" => {:omit, source_spec()},
       "results" => {:list, result_spec()}
     }}
  end

  @doc """
  Validates a decoded document. Returns the normalized document and the
  values to copy into columns, or errors keyed by JSON path.
  """
  @spec validate(term()) :: {:ok, map(), columns()} | {:error, {:invalid, errors()}}
  def validate(document) do
    case normalize(document) do
      {:ok, document} -> check(document)
      {:error, errors} -> invalid(errors)
    end
  end

  defp normalize(document) do
    case JsonDocument.normalize(document) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error, [{[], "must be a JSON object"}]}

      {:error, errors} ->
        spec = document_spec()
        {:error, Enum.map(errors, &contract_error(&1, spec))}
    end
  end

  defp check(document) do
    spec = document_spec()

    errors =
      document
      |> Shape.check(spec, [])
      |> merge_errors(cross_field_errors(document), spec)

    case errors do
      [] -> {:ok, document, columns(document)}
      errors -> invalid(errors)
    end
  end

  defp invalid(errors), do: {:error, {:invalid, render(errors)}}

  defp render(errors) do
    errors
    |> Enum.take(@max_rendered_errors)
    |> Enum.reduce(%{}, fn {path, message}, acc ->
      Map.update(acc, JsonDocument.render_path(path), [message], &Enum.uniq(&1 ++ [message]))
    end)
  end

  # A normalize error can name a submitted key. Keep the path only while
  # every key is one the spec defines, so the error lands on the enclosing
  # object and the key is never echoed.
  defp contract_error({path, message}, spec), do: {contract_path(path, spec, []), message}

  defp contract_path([], _spec, kept), do: Enum.reverse(kept)

  defp contract_path([key | rest], {:object, fields}, kept) when is_binary(key) do
    case Map.fetch(fields, key) do
      {:ok, spec} -> contract_path(rest, unwrap(spec), [key | kept])
      :error -> Enum.reverse(kept)
    end
  end

  defp contract_path([index | rest], {:list, spec}, kept) when is_integer(index),
    do: contract_path(rest, unwrap(spec), [index | kept])

  defp contract_path([index | rest], {:list, spec, _opts}, kept) when is_integer(index),
    do: contract_path(rest, unwrap(spec), [index | kept])

  defp contract_path([key | rest], {:fun, _fun, :partition}, kept) when key in ~w(index count),
    do: contract_path(rest, positive(), [key | kept])

  defp contract_path(_path, _spec, kept), do: Enum.reverse(kept)

  defp unwrap({:omit, spec}), do: spec
  defp unwrap({:nullable, spec}), do: spec
  defp unwrap(spec), do: spec

  defp columns(document) do
    {:ok, started_at, 0} = DateTime.from_iso8601(document["started_at"])
    source = document["source"]

    %{
      run_id: document["run_id"],
      workflow: document["workflow"],
      environment: Map.get(document, "environment"),
      outcome: document["outcome"],
      started_at: started_at,
      duration_ms: document["duration_ms"],
      parallelism: document["parallelism"],
      max_in_flight: document["max_in_flight"],
      graph_sha256: document["graph_sha256"],
      source_commit: source_value(source, "commit"),
      source_dirty: source_value(source, "dirty"),
      host: document["host"]
    }
  end

  defp source_value(source, key) when is_map(source), do: Map.get(source, key)
  defp source_value(_source, _key), do: nil

  # Pair and outcome errors are not produced by the field walk. Insert each
  # one at its path so the 50-error cap keeps document order: `outcome`
  # before `results`, and `results[0].child_run_id` before later statuses.
  #
  # Only the first 50 structural errors can appear in that cap, so the
  # merge starts from that prefix. Each insert is capped again: a later
  # orphan must not make the walk grow with the result count. The kept
  # set matches merging the full lists and then taking 50.
  defp cross_field_errors(document) do
    pair_errors(document) ++ outcome_errors(document)
  end

  defp merge_errors(structural, extra, spec) do
    structural
    |> Enum.take(@max_rendered_errors)
    |> merge_capped(extra, spec)
  end

  defp merge_capped(errors, extra, spec) do
    Enum.reduce(extra, errors, fn error, kept ->
      error |> insert_error(kept, spec) |> Enum.take(@max_rendered_errors)
    end)
  end

  defp insert_error({path, _message} = error, errors, spec) do
    {earlier, later} =
      Enum.split_while(errors, fn {other, _} -> compare_paths(other, path, spec) != :gt end)

    earlier ++ [error | later]
  end

  defp compare_paths(left, right, spec), do: compare_segments(left, right, spec)

  defp compare_segments([], [], _spec), do: :eq
  defp compare_segments([], _right, _spec), do: :gt
  defp compare_segments(_left, [], _spec), do: :lt

  defp compare_segments([same | left], [same | right], spec) do
    compare_segments(left, right, nested_spec(spec, same))
  end

  defp compare_segments([left | _], [right | _], _spec)
       when is_integer(left) and is_integer(right) do
    if left < right, do: :lt, else: :gt
  end

  defp compare_segments([left | _], [right | _], {:object, fields})
       when is_binary(left) and is_binary(right) do
    compare_keys(left, right, Map.keys(fields))
  end

  defp compare_segments([left | _], [right | _], _spec) do
    if left < right, do: :lt, else: :gt
  end

  defp compare_keys(left, right, keys) do
    left_at = Enum.find_index(keys, &(&1 == left))
    right_at = Enum.find_index(keys, &(&1 == right))

    cond do
      left_at == right_at -> :eq
      is_nil(left_at) -> :gt
      is_nil(right_at) -> :lt
      left_at < right_at -> :lt
      true -> :gt
    end
  end

  defp nested_spec({:object, fields}, key) when is_binary(key) do
    case Map.fetch(fields, key) do
      {:ok, spec} -> unwrap(spec)
      :error -> nil
    end
  end

  defp nested_spec({:list, spec}, index) when is_integer(index), do: unwrap(spec)
  defp nested_spec({:list, spec, _opts}, index) when is_integer(index), do: unwrap(spec)
  defp nested_spec({:fun, _fun, :partition}, key) when key in ~w(index count), do: positive()
  defp nested_spec(_spec, _segment), do: nil

  defp pair_errors(document) do
    caller_pair(document) ++ child_pairs(Map.get(document, "results"))
  end

  defp caller_pair(document) do
    parent = Map.get(document, "parent_run_id", :absent)
    caller = Map.get(document, "caller_job", :absent)

    cond do
      present?(parent) and not present?(caller) -> [{["parent_run_id"], "is invalid"}]
      present?(caller) and not present?(parent) -> [{["caller_job"], "is invalid"}]
      true -> []
    end
  end

  defp child_pairs(results) when is_list(results) do
    results |> Enum.with_index() |> Enum.flat_map(&child_pair/1)
  end

  defp child_pairs(_results), do: []

  defp child_pair({result, index}) when is_map(result) do
    child = Map.get(result, "child_run_id", :absent)
    workflow = Map.get(result, "workflow", :absent)

    if present?(child) and not present?(workflow),
      do: [{["results", index, "child_run_id"], "is invalid"}],
      else: []
  end

  defp child_pair(_other), do: []

  defp present?(:absent), do: false
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp outcome_errors(%{"outcome" => outcome, "results" => results})
       when outcome in @outcomes and is_list(results) do
    if Enum.all?(results, &valid_status?/1), do: outcome_consistency(outcome, results), else: []
  end

  defp outcome_errors(_document), do: []

  defp valid_status?(%{"status" => status}) when status in @statuses, do: true
  defp valid_status?(_result), do: false

  defp outcome_consistency(outcome, results) do
    failed = Enum.any?(results, &failed_status?/1)
    cancelled = Enum.any?(results, &(&1["status"] == "cancelled"))

    cond do
      outcome == "failed" and not failed -> [{["outcome"], "is invalid"}]
      outcome != "failed" and failed -> [{["outcome"], "is invalid"}]
      outcome == "passed" and cancelled -> [{["outcome"], "is invalid"}]
      true -> []
    end
  end

  defp failed_status?(%{"status" => status}), do: status in ["failed", "timed_out"]

  defp name, do: {:string, min: 1, max: @max_name_bytes, no_control: true, non_blank: true}
  defp uuid, do: {:string, format: @uuid}
  defp nonneg, do: {:int, 0}
  defp positive, do: {:int, 1}
  defp text, do: {:string, max: @max_text_bytes}

  defp host_spec do
    {:object,
     %{
       "os" => name(),
       "arch" => name(),
       "logical_cpus" => positive(),
       "mem_total_bytes" => {:omit, nonneg()},
       "mem_available_bytes" => {:omit, nonneg()}
     }}
  end

  defp source_spec do
    {:object,
     %{
       "commit" => {:string, format: @commit},
       "dirty" => {:omit, :boolean}
     }}
  end

  defp result_spec do
    {:object,
     %{
       "name" => name(),
       "partition" => {:omit, {:fun, &partition_errors/2, :partition}},
       "workflow" => {:omit, name()},
       "child_run_id" => {:omit, uuid()},
       "status" => {:enum, @statuses},
       "exit_code" => {:nullable, {:fun, &exit_code_errors/2, :exit_code}},
       "command" => {:nullable, text()},
       "error" => {:nullable, text()},
       "duration_ms" => nonneg(),
       "started" => :boolean,
       "blocked_ms" => nonneg(),
       "queued_ms" => nonneg(),
       "commands" => {:omit, {:list, command_spec(), min: 1, max: @max_list_entries}}
     }}
  end

  defp command_spec do
    {:object,
     %{
       "kind" => {:enum, @kinds},
       "step" => {:omit, name()},
       "wall_ms" => nonneg(),
       "cpu_user_ms" => {:omit, nonneg()},
       "cpu_system_ms" => {:omit, nonneg()},
       "peak_rss_bytes" => {:omit, positive()}
     }}
  end

  defp schema_version_errors(1, _path), do: []
  defp schema_version_errors(value, path) when is_integer(value), do: [{path, "is invalid"}]
  defp schema_version_errors(_value, path), do: [{path, "must be an integer"}]

  defp started_at_errors(value, path) when is_binary(value) do
    if started_at_valid?(value), do: [], else: [{path, "is invalid"}]
  end

  defp started_at_errors(_value, path), do: [{path, "must be a string"}]

  defp started_at_valid?(value) do
    Regex.match?(@started_at, value) and match?({:ok, _datetime, 0}, DateTime.from_iso8601(value))
  end

  defp exit_code_errors(value, _path)
       when is_integer(value) and value in @min_exit_code..@max_exit_code,
       do: []

  defp exit_code_errors(value, path) when is_integer(value), do: [{path, "is invalid"}]
  defp exit_code_errors(_value, path), do: [{path, "must be an integer"}]

  defp partition_errors(value, path) when is_map(value) do
    value
    |> Shape.check_into(partition_spec(), path, [])
    |> partition_bounds(value, path)
  end

  defp partition_errors(_value, path), do: [{path, "must be an object"}]

  defp partition_spec, do: {:object, %{"index" => positive(), "count" => positive()}}

  defp partition_bounds(errors, %{"index" => index, "count" => count}, path)
       when is_integer(index) and index >= 1 and is_integer(count) and count >= 1 do
    if index <= count and count <= @max_partitions,
      do: errors,
      else: [{path, "is invalid"} | errors]
  end

  defp partition_bounds(errors, _value, _path), do: errors
end
