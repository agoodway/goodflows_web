defmodule GoodFlows.WorkflowRuns.Validator do
  @moduledoc """
  Validates a goodflows run-history document at `schema_version` 1.

  The allowlist mirrors goodci `Record` (`src/history.rs`), including the
  workflow-call fields added without a version bump: `parent_run_id` and
  `caller_job` together or not at all, and a result's `workflow` with an
  optional `child_run_id`. It also accepts the CLI upload envelope
  (goodflows `src/reporting/run_contract.rs`): an optional `source.branch`,
  an optional top-level `ci`, and an optional top-level `graph`. It also
  accepts an optional top-level `links` (goodflows `add-run-links`): an
  object with only `threads` and `tickets`, at least one of them. Optional
  keys are omit-only. Nullable keys are always present and may be null:
  a result's `command`, `exit_code` and `error`, a graph job's `command`,
  `partitions`, `timeout_secs` and `condition`, and a graph step's `shell`
  and `condition`. Any other key is unknown.

  When `graph` is present, its job names are unique, every `depends_on`
  entry names a graph job, dependencies have no cycle, and every result
  `name` is a graph job. A called workflow is referenced by
  `call.graph_sha256` and never inlined: `call` has exactly `workflow` and
  `graph_sha256`.

  `links.threads` entries are unique `https` URLs that must already be in
  the form `reqwest::Url` (WHATWG) serializes: no userinfo, query or
  fragment, only RFC 3986 `pchar` and `/` in the path, a lowercase host
  without `%`, a canonical IP host, no empty, zero-padded or 443 port, a
  nonempty path and no dot segment (including `%2e` spellings). Percent
  triplets are compared as written, never decoded or recased. A URL that
  is not in that form is `must be normalized`; it is never rewritten.
  `links.tickets` entries are printable ASCII other than `,` and unique
  ignoring ASCII case.

  `validate/1` takes a decoded document (`JsonDocument.decode/1`, or a
  plain map). It normalizes first, so duplicate keys, NUL characters and
  integers outside `±(2^53 - 1)` are fixed errors whose paths are cut back
  to contract keys. The structural pass then checks presence, types and
  bounds. Outcome consistency runs only when every result status is valid.

  Instance caps live here: names are at most 64 bytes, `source.branch` and
  `ci.run_id` at most 256, `ci.url` and each thread URL at most 2,048,
  tickets 1 to 64, `command`, `error` and graph command and condition text
  at most 1,024 bytes, `requested_jobs`, `commands` and `graph.jobs` 1 to
  1,024 entries, `links.threads` and `links.tickets` 1 to 32 entries,
  `depends_on` and `steps` at most 1,024 entries, and a partition count at
  most 64. Nesting deeper than
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
  @max_branch_bytes 256
  @max_ci_run_id_bytes 256
  @max_url_bytes 2_048
  @max_partitions 64
  @max_links 32
  @max_ticket_bytes 64
  @max_port 65_535
  @max_rendered_errors 50
  @min_exit_code -2_147_483_648
  @max_exit_code 2_147_483_647

  @outcomes ~w(passed failed cancelled)
  @statuses ~w(passed failed skipped timed_out cancelled)
  @kinds ~w(condition command)
  @ci_providers ~w(github_actions)
  @condition_kinds ~w(expression shell)
  @partition_strategies ~w(index)

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @started_at ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/
  @ticket ~r/\A[!-+\--~]+\z/
  # Every byte an RFC 3986 `pchar` or `/`, every `%` a full triplet.
  @url_path ~r/\A(?:[A-Za-z0-9\-._~!$&'()*+,;=:@\/]|%[0-9A-Fa-f]{2})*\z/
  @dot_segments ~w(. %2e .. .%2e %2e. %2e%2e)
  # WHATWG "ends in a number": the last label is digits, or `0x` and hex.
  @numeric_label ~r/\A(?:[0-9]+|0[xX][0-9A-Fa-f]*)\z/
  @ipv4_octet "(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
  @ipv4 Regex.compile!("\\A#{@ipv4_octet}(?:\\.#{@ipv4_octet}){3}\\z")

  @typedoc "Validation errors keyed by rendered JSON path."
  @type errors :: %{String.t() => [String.t()]}

  @typedoc """
  Values copied into `workflow_runs` columns. Absent omit-only fields are
  `nil`. `source_dirty` is `false` when the document sent `false`. `ci` is
  the document's `ci` object. `link_tickets` holds `links.tickets`
  ASCII-lowercased and `link_threads` holds `links.threads` as sent; both
  are `[]` when absent.
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
          source_branch: String.t() | nil,
          ci: map() | nil,
          host: map(),
          link_tickets: [String.t()],
          link_threads: [String.t()]
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

  @doc "Whether `value` is a lowercase canonical UUID, the rule for `run_id`."
  @spec canonical_uuid?(term()) :: boolean()
  def canonical_uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
  def canonical_uuid?(_value), do: false

  @doc """
  Whether `value` follows the name rule: 1 to 64 UTF-8 bytes, no control
  characters, and not only whitespace.

  The rule is the `GoodFlows.TestReports.Shape` string check used for names
  in the document (`name/0`). Invalid UTF-8 is rejected here, because that
  check trims the string.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(value) when is_binary(value) do
    String.valid?(value) and Shape.check(value, name(), []) == []
  end

  def valid_name?(_value), do: false

  @doc "Whether `value` is `passed`, `failed` or `cancelled`."
  @spec valid_outcome?(term()) :: boolean()
  def valid_outcome?(value), do: value in @outcomes

  @doc "Whether `value` is 40 or 64 lowercase hex characters."
  @spec valid_commit?(term()) :: boolean()
  def valid_commit?(value) when is_binary(value), do: Regex.match?(@commit, value)
  def valid_commit?(_value), do: false

  @doc """
  Whether `value` follows the `source.branch` rule: 1 to 256 UTF-8 bytes
  and no control characters.
  """
  @spec valid_branch?(term()) :: boolean()
  def valid_branch?(value) when is_binary(value) do
    String.valid?(value) and Shape.check(value, branch(), []) == []
  end

  def valid_branch?(_value), do: false

  @doc "Whether `value` is 64 lowercase hex characters."
  @spec valid_graph_sha256?(term()) :: boolean()
  def valid_graph_sha256?(value) when is_binary(value), do: Regex.match?(@sha256, value)
  def valid_graph_sha256?(_value), do: false

  @doc """
  Whether `value` follows the ticket rule: 1 to 64 bytes of printable
  ASCII (`!` to `~`) other than `,`.
  """
  @spec valid_ticket?(term()) :: boolean()
  def valid_ticket?(value) when is_binary(value), do: Shape.check(value, ticket(), []) == []
  def valid_ticket?(_value), do: false

  @doc """
  Whether `value` is a thread URL already in normalized form (see the
  module documentation). It is checked as written, never rewritten.
  """
  @spec valid_thread_url?(term()) :: boolean()
  def valid_thread_url?(value), do: thread_url_errors(value, []) == []

  @doc """
  Renders `{path, message}` errors (as from `GoodFlows.JsonDocument.normalize/1`)
  against the document spec.

  A path that names a key outside the spec is cut back to the enclosing
  object, so a submitted key is never echoed. At most the first 50 errors
  are returned.
  """
  @spec render_errors([JsonDocument.error()]) :: errors()
  def render_errors(errors) when is_list(errors) do
    spec = document_spec()
    errors |> Enum.map(&contract_error(&1, spec)) |> render()
  end

  @doc """
  The `GoodFlows.TestReports.Shape` spec of a run-history document.
  Optional keys use `{:omit, spec}` (absent or a value, never null).
  Nullable keys use `{:nullable, spec}` and are required.
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
       "ci" => {:omit, ci_spec()},
       "links" => {:omit, links_spec()},
       "results" => {:list, result_spec()},
       "graph" => {:omit, graph_spec()}
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
      source_branch: source_value(source, "branch"),
      ci: Map.get(document, "ci"),
      host: document["host"],
      link_tickets: document |> link_list("tickets") |> Enum.map(&String.downcase(&1, :ascii)),
      link_threads: link_list(document, "threads")
    }
  end

  defp link_list(%{"links" => links}, key), do: Map.get(links, key, [])
  defp link_list(_document, _key), do: []

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
    pair_errors(document) ++
      outcome_errors(document) ++ graph_errors(document) ++ links_errors(document)
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

  # Graph consistency runs once `graph.jobs` is a list within bounds whose
  # jobs all have a string `name` and a list of string `depends_on`. A
  # cycle is looked for only when names are unique and every dependency
  # is known, so each dependency resolves to one job.
  defp graph_errors(%{"graph" => %{"jobs" => jobs}} = document)
       when is_list(jobs) and jobs != [] and length(jobs) <= @max_list_entries do
    if Enum.all?(jobs, &graph_job_shape?/1),
      do: graph_consistency(jobs, Map.get(document, "results")),
      else: []
  end

  defp graph_errors(_document), do: []

  defp graph_job_shape?(%{"name" => name, "depends_on" => deps})
       when is_binary(name) and is_list(deps),
       do: Enum.all?(deps, &is_binary/1)

  defp graph_job_shape?(_job), do: false

  defp graph_consistency(jobs, results) do
    jobs = Enum.with_index(jobs)
    {index, duplicates} = Enum.reduce(jobs, {%{}, []}, &index_job/2)
    unknown = unknown_dependencies(jobs, index)

    cycle =
      if duplicates == [] and unknown == [], do: cycle_errors(jobs, index), else: []

    Enum.reverse(duplicates) ++ unknown ++ cycle ++ unknown_results(results, index)
  end

  defp index_job({%{"name" => name}, i}, {index, duplicates}) do
    if Map.has_key?(index, name),
      do: {index, [{["graph", "jobs", i, "name"], "must be unique"} | duplicates]},
      else: {Map.put(index, name, i), duplicates}
  end

  defp unknown_dependencies(jobs, index) do
    for {%{"depends_on" => deps}, i} <- jobs,
        {dep, j} <- Enum.with_index(deps),
        not Map.has_key?(index, dep),
        do: {["graph", "jobs", i, "depends_on", j], "must name a graph job"}
  end

  defp unknown_results(results, index) when is_list(results) do
    for {%{"name" => name}, i} <- Enum.with_index(results),
        is_binary(name),
        not Map.has_key?(index, name),
        do: {["results", i, "name"], "must name a graph job"}
  end

  defp unknown_results(_results, _index), do: []

  # Depth-first search. The error is on the `depends_on` of the job whose
  # dependency closes the cycle, as goodflows reports it.
  defp cycle_errors(jobs, index) do
    edges =
      Map.new(jobs, fn {%{"depends_on" => deps}, i} -> {i, Enum.map(deps, &index[&1])} end)

    result =
      Enum.reduce_while(0..(map_size(edges) - 1), %{}, fn node, colors ->
        case visit(node, edges, colors) do
          {:ok, colors} -> {:cont, colors}
          {:cycle, _node} = cycle -> {:halt, cycle}
        end
      end)

    case result do
      {:cycle, node} -> [{["graph", "jobs", node, "depends_on"], "must not form a cycle"}]
      _colors -> []
    end
  end

  defp visit(node, edges, colors) do
    case colors do
      %{^node => :done} -> {:ok, colors}
      _unseen -> visit_deps(node, edges, Map.put(colors, node, :active))
    end
  end

  defp visit_deps(node, edges, colors) do
    edges
    |> Map.fetch!(node)
    |> Enum.reduce_while({:ok, colors}, fn dep, {:ok, colors} ->
      if colors[dep] == :active,
        do: {:halt, {:cycle, node}},
        else: dep |> visit(edges, colors) |> continue_visit()
    end)
    |> case do
      {:ok, colors} -> {:ok, Map.put(colors, node, :done)}
      cycle -> cycle
    end
  end

  defp continue_visit({:ok, _colors} = ok), do: {:cont, ok}
  defp continue_visit(cycle), do: {:halt, cycle}

  # An object with neither list is empty. Repeats are looked for only in
  # a list within bounds whose entries are all valid, so a structural
  # error is not reported twice. Tickets compare ignoring ASCII case;
  # thread URLs are already normalized and compare exactly.
  @doc """
  Cross-entry `links` checks of a document that has `links`: an empty
  object, and repeated thread URLs or tickets (ignoring ASCII case).
  Errors have forward paths starting at `links`. Change request bodies
  reuse it with `links_spec/0`.
  """
  @spec links_errors(map()) :: [JsonDocument.error()]
  def links_errors(%{"links" => links}) when is_map(links) do
    empty =
      if Map.has_key?(links, "threads") or Map.has_key?(links, "tickets"),
        do: [],
        else: [{["links"], "must not be empty"}]

    empty ++
      repeats(links, "threads", &valid_thread_url?/1, & &1) ++
      repeats(links, "tickets", &valid_ticket?/1, &String.downcase(&1, :ascii))
  end

  def links_errors(_document), do: []

  defp repeats(links, key, valid?, compare_as) do
    with {:ok, list} when is_list(list) and list != [] and length(list) <= @max_links <-
           Map.fetch(links, key),
         true <- Enum.all?(list, valid?) do
      list |> Enum.map(compare_as) |> repeat_errors(key)
    else
      _other -> []
    end
  end

  defp repeat_errors(values, key) do
    {errors, _seen} =
      values
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {value, i}, {errors, seen} ->
        if MapSet.member?(seen, value),
          do: {[{["links", key, i], "must be unique"} | errors], seen},
          else: {errors, MapSet.put(seen, value)}
      end)

    Enum.reverse(errors)
  end

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

  defp branch, do: {:string, min: 1, max: @max_branch_bytes, no_control: true}

  defp source_spec do
    {:object,
     %{
       "commit" => {:string, format: @commit},
       "dirty" => {:omit, :boolean},
       "branch" => {:omit, branch()}
     }}
  end

  defp ci_spec do
    {:object,
     %{
       "provider" => {:enum, @ci_providers},
       "event" => {:omit, name()},
       "run_id" => {:omit, {:string, min: 1, max: @max_ci_run_id_bytes, no_control: true}},
       "attempt" => {:omit, positive()},
       "pull_request" => {:omit, positive()},
       "runner" => {:omit, name()},
       "url" => {:omit, {:fun, &ci_url_errors/2, :ci_url}}
     }}
  end

  @doc "The `GoodFlows.TestReports.Shape` spec of a `links` object."
  @spec links_spec() :: Shape.spec()
  def links_spec do
    {:object,
     %{
       "threads" =>
         {:omit, {:list, {:fun, &thread_url_errors/2, :thread_url}, min: 1, max: @max_links}},
       "tickets" => {:omit, {:list, ticket(), min: 1, max: @max_links}}
     }}
  end

  defp ticket, do: {:string, min: 1, max: @max_ticket_bytes, format: @ticket}

  defp graph_spec do
    {:object, %{"jobs" => {:list, graph_job_spec(), min: 1, max: @max_list_entries}}}
  end

  defp graph_job_spec do
    {:object,
     %{
       "name" => name(),
       "command" => {:nullable, text()},
       "depends_on" => {:list, name(), max: @max_list_entries},
       "partitions" => {:nullable, graph_partitions_spec()},
       "timeout_secs" => {:nullable, positive()},
       "shell" => :boolean,
       "condition" => {:nullable, condition_spec()},
       "steps" => {:list, graph_step_spec(), max: @max_list_entries},
       "call" => {:omit, call_spec()}
     }}
  end

  defp graph_partitions_spec do
    {:object,
     %{
       "count" => {:fun, &partition_count_errors/2, :partition_count},
       "strategy" => {:enum, @partition_strategies}
     }}
  end

  defp condition_spec, do: {:object, %{"kind" => {:enum, @condition_kinds}, "text" => text()}}

  defp graph_step_spec do
    {:object,
     %{
       "id" => name(),
       "command" => text(),
       "shell" => {:nullable, :boolean},
       "condition" => {:nullable, condition_spec()}
     }}
  end

  # A called workflow is referenced by its graph hash, never inlined.
  defp call_spec do
    {:object, %{"workflow" => name(), "graph_sha256" => {:string, format: @sha256}}}
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

  defp partition_count_errors(value, _path)
       when is_integer(value) and value in 1..@max_partitions,
       do: []

  defp partition_count_errors(value, path) when is_integer(value) and value < 1,
    do: [{path, "must be a positive integer"}]

  defp partition_count_errors(value, path) when is_integer(value), do: [{path, "is invalid"}]
  defp partition_count_errors(_value, path), do: [{path, "must be an integer"}]

  # An absolute `https` URL with a host. goodflows builds it from GitHub
  # Actions variables that allow no spaces or control characters.
  defp ci_url_errors(value, path) when is_binary(value) do
    cond do
      byte_size(value) > @max_url_bytes -> [{path, "is too long"}]
      https_url?(value) -> []
      true -> [{path, "is invalid"}]
    end
  end

  defp ci_url_errors(_value, path), do: [{path, "must be a string"}]

  defp https_url?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> true
      _other -> false
    end
  end

  # Design D2: the URL must already equal its `reqwest::Url` (WHATWG)
  # serialization. It is checked as written and never rewritten, and
  # percent triplets are never decoded or recased. `URI.new/1` accepts
  # `%zz` and a trailing `%` in a path, so the path rule is checked here.
  defp thread_url_errors(value, path) when is_binary(value) do
    if byte_size(value) > @max_url_bytes,
      do: [{path, "is too long"}],
      else: thread_url_form_errors(value, path)
  end

  defp thread_url_errors(_value, path), do: [{path, "must be a string"}]

  defp thread_url_form_errors(value, path) do
    case parse_thread_url(value) do
      {:ok, uri} ->
        if normalized_url?(value, uri), do: [], else: [{path, "must be normalized"}]

      :error ->
        [{path, "is invalid"}]
    end
  end

  defp parse_thread_url("https://" <> _rest = value) do
    with {:ok, %URI{host: host, port: port, userinfo: nil, query: nil, fragment: nil} = uri}
         when is_binary(host) and host != "" and is_integer(port) and port <= @max_port <-
           URI.new(value),
         true <- Regex.match?(@url_path, uri.path || "") do
      {:ok, uri}
    else
      _other -> :error
    end
  end

  defp parse_thread_url(_value), do: :error

  # `URI.to_string/1` drops an empty or 443 port and unpads a port, so a
  # round trip catches `:`, `:443`, `:0443` and `:080`.
  defp normalized_url?(value, %URI{host: host, path: path} = uri) do
    URI.to_string(uri) == value and is_binary(path) and path != "" and
      not Enum.any?(String.split(path, "/"), &dot_segment?/1) and
      not Regex.match?(~r/[A-Z%]/, host) and canonical_ip_host?(host)
  end

  defp dot_segment?(segment), do: String.downcase(segment, :ascii) in @dot_segments

  # `URI` strips the brackets of an IPv6 host, and a reg-name has no `:`.
  defp canonical_ip_host?(host) do
    cond do
      String.contains?(host, ":") -> canonical_ipv6?(host)
      ends_in_number?(host) -> Regex.match?(@ipv4, host)
      true -> true
    end
  end

  defp ends_in_number?(host) do
    last =
      case host |> String.split(".") |> Enum.reverse() do
        ["", label | _rest] -> label
        [label | _rest] -> label
      end

    Regex.match?(@numeric_label, last)
  end

  defp canonical_ipv6?(host) do
    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, address} -> ipv6_string(Tuple.to_list(address)) == host
      {:error, _reason} -> false
    end
  end

  # WHATWG IPv6 serialization: lowercase hex without leading zeros, the
  # first longest run of two or more zero pieces as `::`, no dotted quad.
  defp ipv6_string(pieces) do
    case longest_zero_run(pieces) do
      {start, length} when length >= 2 ->
        hex_pieces(Enum.take(pieces, start)) <>
          "::" <> hex_pieces(Enum.drop(pieces, start + length))

      _shorter ->
        hex_pieces(pieces)
    end
  end

  defp hex_pieces(pieces),
    do: Enum.map_join(pieces, ":", &(&1 |> Integer.to_string(16) |> String.downcase()))

  # `Enum.max_by/3` keeps the first of equal runs.
  defp longest_zero_run(pieces) do
    pieces
    |> Enum.with_index()
    |> Enum.chunk_by(fn {piece, _i} -> piece == 0 end)
    |> Enum.filter(&match?([{0, _i} | _rest], &1))
    |> Enum.max_by(&length/1, fn -> [] end)
    |> case do
      [{0, start} | _rest] = run -> {start, length(run)}
      [] -> {0, 0}
    end
  end

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
