defmodule GoodFlows.ReviewPolicies.Document do
  @moduledoc """
  The `review-policy/1` document: its version 0 default, the effective
  document with defaults filled in, the settings active in this server
  version, and the validator for write bodies.

  A policy has `format` `review-policy/1` and the optional sections
  `scenarios`, `evidence`, `claims`, `paths`, `size`, `coverage` and
  `merge`, each with fixed optional keys (design D5). An omitted section or
  key takes its version 0 value in `effective/1`; `paths` is replaced as a
  whole. An unknown section or key, or a null, is an error on that key. The
  stored document is kept as given.

  `active_settings/0` lists the dotted settings that take effect in this
  server version. Later phases add their settings to that one list; a
  setting missing from it never changes a verdict.
  """

  alias GoodFlows.ReviewPolicies.Glob
  alias GoodFlows.TestReports.Shape
  alias GoodFlows.WorkflowRuns.Validator, as: RunValidator

  @format "review-policy/1"
  @outcomes ~w(needs_review blocked ignore)
  @review_outcomes ~w(needs_review ignore)
  @diff_only_outcomes ~w(needs_review weakening ignore)
  @approvers ~w(any other_member admin)
  @proof_levels ~w(stated pointed walked ran)
  @max_required_workflows 32
  @max_globs 100
  @max_note_bytes 1_024
  @lease_ttl ~r/\A([1-9][0-9]{0,6})([smh])\z/
  @min_lease_seconds 60
  @max_lease_seconds 3_600

  @default %{
    "format" => @format,
    "scenarios" => %{
      "require_approved_intent" => false,
      "should_failures" => "needs_review",
      "spec_gaps" => "ignore",
      "approver" => "any",
      "diff_only" => "needs_review"
    },
    "evidence" => %{"required_workflows" => [], "ignore_paths" => ["docs/**", "**/*.md"]},
    "claims" => %{
      "one_way_door" => "needs_review",
      "min_proof_level" => "ran",
      "open_items" => "needs_review"
    },
    "paths" => [%{"glob" => "app/priv/repo/migrations/**", "outcome" => "needs_review"}],
    "size" => %{"max_changed_files" => 40, "max_changed_lines" => 1500},
    "coverage" => %{"unmapped_areas" => "ignore", "undriven_features" => "ignore"},
    "merge" => %{"lease_ttl" => "10m", "regrade_merge_result" => true}
  }

  @active_settings ~w(
    scenarios.require_approved_intent
    scenarios.should_failures
    scenarios.spec_gaps
    scenarios.approver
    scenarios.diff_only
    evidence.required_workflows
    evidence.ignore_paths
    claims.one_way_door
    claims.min_proof_level
    claims.open_items
    paths
    size.max_changed_files
    size.max_changed_lines
    coverage.unmapped_areas
    coverage.undriven_features
    merge.lease_ttl
    merge.regrade_merge_result
  )

  @typedoc "A validated write body."
  @type write :: %{previous_version: non_neg_integer(), policy: map(), note: String.t() | nil}

  @doc "The only accepted `format`."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The version 0 document, used by a project that never wrote one."
  @spec default() :: map()
  def default, do: @default

  @doc "The dotted setting names that take effect in this server version."
  @spec active_settings() :: [String.t()]
  def active_settings, do: @active_settings

  @doc "Proof levels, lowest first."
  @spec proof_levels() :: [String.t()]
  def proof_levels, do: @proof_levels

  @doc """
  The effective document: `policy` with every omitted section and key
  filled from the version 0 default. `paths` is taken whole when given.
  """
  @spec effective(map()) :: map()
  def effective(policy) when is_map(policy) do
    Map.new(@default, fn
      {"format", value} -> {"format", value}
      {"paths", value} -> {"paths", Map.get(policy, "paths", value)}
      {section, defaults} -> {section, Map.merge(defaults, Map.get(policy, section, %{}))}
    end)
  end

  @doc """
  Validates a normalized write body: `previous_version`, `policy` and an
  optional `note`, and no other key. Errors are `{path, message}` pairs.
  """
  @spec validate_write(term()) :: {:ok, write()} | {:error, [GoodFlows.JsonDocument.error()]}
  def validate_write(body) do
    spec =
      {:object,
       %{
         "previous_version" => {:int, 0},
         "policy" => policy_spec(),
         "note" => {:omit, {:string, min: 1, max: @max_note_bytes}}
       }}

    case Shape.check(body, spec, []) do
      [] ->
        {:ok,
         %{
           previous_version: body["previous_version"],
           policy: body["policy"],
           note: Map.get(body, "note")
         }}

      errors ->
        {:error, errors}
    end
  end

  defp policy_spec do
    {:object,
     %{
       "format" => {:enum, [@format]},
       "scenarios" =>
         section(%{
           "require_approved_intent" => :boolean,
           "should_failures" => {:enum, @review_outcomes},
           "spec_gaps" => {:enum, @review_outcomes},
           "approver" => {:enum, @approvers},
           "diff_only" => {:enum, @diff_only_outcomes}
         }),
       "evidence" =>
         section(%{
           "required_workflows" => {:fun, &required_workflows_errors/2, :required_workflows},
           "ignore_paths" => {:list, glob_spec(), max: @max_globs}
         }),
       "claims" =>
         section(%{
           "one_way_door" => {:enum, @outcomes},
           "min_proof_level" => {:enum, @proof_levels},
           "open_items" => {:enum, @outcomes}
         }),
       "paths" => {:omit, {:fun, &paths_errors/2, :paths}},
       "size" => section(%{"max_changed_files" => {:int, 1}, "max_changed_lines" => {:int, 1}}),
       "coverage" =>
         section(%{
           "unmapped_areas" => {:enum, @outcomes},
           "undriven_features" => {:enum, @outcomes}
         }),
       "merge" =>
         section(%{
           "lease_ttl" => {:fun, &lease_ttl_errors/2, :lease_ttl},
           "regrade_merge_result" => :boolean
         })
     }}
  end

  defp section(fields), do: {:omit, {:object, Map.new(fields, fn {k, v} -> {k, {:omit, v}} end)}}

  defp glob_spec, do: {:fun, &glob_errors/2, :glob}

  defp glob_errors(value, path) do
    case Glob.error(value) do
      nil -> []
      message -> [{path, message}]
    end
  end

  # Names follow the workflow-run name rule.
  defp required_workflows_errors(value, path) when is_list(value) do
    cond do
      length(value) > @max_required_workflows ->
        [{path, "must not have more than #{@max_required_workflows} entries"}]

      not Enum.all?(value, &RunValidator.valid_name?/1) ->
        [{path, "must hold workflow names"}]

      not distinct?(value) ->
        [{path, "must not repeat a workflow"}]

      true ->
        []
    end
  end

  defp required_workflows_errors(_value, path), do: [{path, "must be an array"}]

  defp paths_errors(value, path) do
    entry = {:object, %{"glob" => glob_spec(), "outcome" => {:enum, @outcomes}}}

    case Shape.check_into(value, {:list, entry, max: @max_globs}, path, []) do
      [] ->
        if distinct?(Enum.map(value, & &1["glob"])),
          do: [],
          else: [{path, "must not repeat a glob"}]

      errors ->
        errors
    end
  end

  defp lease_ttl_errors(value, path) when is_binary(value) do
    with [_all, n, unit] <- Regex.run(@lease_ttl, value),
         seconds when seconds in @min_lease_seconds..@max_lease_seconds <-
           String.to_integer(n) * unit_seconds(unit) do
      []
    else
      _other -> [{path, "must be a duration from 1m to 1h such as 90s, 10m or 1h"}]
    end
  end

  defp lease_ttl_errors(_value, path), do: [{path, "must be a string"}]

  @doc """
  The seconds of a valid `merge.lease_ttl` (`<n>s`, `<n>m` or `<n>h`), such
  as 600 for the default `10m`.
  """
  @spec lease_ttl_seconds(String.t()) :: pos_integer()
  def lease_ttl_seconds(value) do
    [_all, n, unit] = Regex.run(@lease_ttl, value)
    String.to_integer(n) * unit_seconds(unit)
  end

  defp unit_seconds("s"), do: 1
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3_600

  defp distinct?(list), do: length(Enum.uniq(list)) == length(list)
end
