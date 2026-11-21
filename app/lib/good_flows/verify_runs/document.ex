defmodule GoodFlows.VerifyRuns.Document do
  @moduledoc """
  Validates a `verify-run/1` document (design D5).

  Required keys: `format`, `run_id` (lowercase canonical UUID),
  `started_at` and `finished_at` (RFC 3339, `finished_at` not before
  `started_at`), `source` (`commit` of 40 or 64 lowercase hex, `branch` of
  1 to 256 bytes without control characters or null, `dirty`, and at most
  10,000 `changed_files`), `scenario_set` (`digest`, `source`), `results`,
  `features` (at most 500), `drift` (at most 100 strings of at most 1,024
  bytes) and `artifacts` (at most 200). Optional: `merge_result` (null or
  `{base, commit}`), `links` (the workflow-run `links` shape) and
  `workflow_run_id` (null or a lowercase UUID). Any other key is unknown.

  A `results` entry is `{id, result, failed_step, reason, evidence}`: `id`
  a scenario ID (`GoodFlows.ScenarioSets.Document.valid_id?/1`), unique in
  string form; `evidence` names declared artifact IDs. An artifact larger
  than 50 MB is `{:error, :artifact_too_large}` (`413`).

  Errors are keyed by path, cut at the first list index (`results`,
  `artifacts`, `features`, `source.changed_files`), with fixed messages.
  Any other `format` is one error on `format`. Matching `results` against
  the named scenario set is done by `GoodFlows.VerifyRuns`.
  """

  alias GoodFlows.DocumentErrors
  alias GoodFlows.ScenarioSets.Document, as: SetDocument
  alias GoodFlows.TestReports.Shape
  alias GoodFlows.WorkflowRuns.Validator, as: RunValidator

  @format "verify-run/1"
  @outcomes ~w(passed failed not_run)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @commit ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @artifact_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @mime ~r/\A[A-Za-z0-9!#$&^_.+-]{1,127}\/[A-Za-z0-9!#$&^_.+-]{1,127}\z/
  @time ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z/
  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @max_artifact_bytes 52_428_800
  @max_artifacts 200
  @max_features 500
  @max_drift 100
  @max_changed_files 10_000

  @typedoc "Values copied into `verify_runs` columns."
  @type columns :: %{
          run_id: String.t(),
          started_at: DateTime.t(),
          finished_at: DateTime.t(),
          source_commit: String.t(),
          dirty: boolean(),
          scenario_set_digest: String.t(),
          scenario_set_source: String.t(),
          merge_result: boolean()
        }

  @doc "The only accepted `format`."
  @spec format() :: String.t()
  def format, do: @format

  @doc "The largest accepted artifact `size` in bytes."
  @spec max_artifact_bytes() :: pos_integer()
  def max_artifact_bytes, do: @max_artifact_bytes

  @doc "Validates a normalized body; returns the document and its column values."
  @spec validate(term()) ::
          {:ok, map(), columns()}
          | {:error, :artifact_too_large | {:invalid_body, DocumentErrors.errors()}}
  def validate(%{"format" => format}) when format != @format,
    do: {:error, {:invalid_body, %{"format" => ["must be #{@format}"]}}}

  def validate(body) do
    with [] <- body |> Shape.check(spec(), []) |> cut(),
         :ok <- check_sizes(body),
         [] <- cross_errors(body) do
      {:ok, body, columns(body)}
    else
      {:error, :artifact_too_large} -> {:error, :artifact_too_large}
      errors -> {:error, {:invalid_body, DocumentErrors.render(errors)}}
    end
  end

  defp spec do
    {:object,
     %{
       "format" => {:enum, [@format]},
       "run_id" => {:string, format: @uuid},
       "started_at" => time(),
       "finished_at" => time(),
       "source" =>
         {:object,
          %{
            "commit" => {:string, format: @commit},
            "branch" => {:nullable, {:string, min: 1, max: 256, no_control: true}},
            "dirty" => :boolean,
            "changed_files" => {:list, path(), max: @max_changed_files}
          }},
       "scenario_set" =>
         {:object,
          %{"digest" => {:string, format: @sha256}, "source" => {:enum, ~w(intent diff)}}},
       "results" => {:list, result_spec(), max: 200},
       "features" => {:list, feature_spec(), max: @max_features},
       "drift" => {:list, {:string, max: 1_024}, max: @max_drift},
       "artifacts" => {:list, artifact_spec(), max: @max_artifacts},
       "merge_result" =>
         {:optional,
          {:nullable,
           {:object,
            %{"base" => {:string, format: @commit}, "commit" => {:string, format: @commit}}}}},
       "links" => {:omit, RunValidator.links_spec()},
       "workflow_run_id" => {:optional, {:nullable, {:string, format: @uuid}}}
     }}
  end

  defp result_spec do
    {:object,
     %{
       "id" => {:fun, &id_errors/2, :scenario_id},
       "result" => {:enum, @outcomes},
       "failed_step" => {:nullable, {:string, max: 4_096}},
       "reason" => {:nullable, {:string, max: 4_096}},
       "evidence" => {:list, {:string, format: @artifact_id}, max: @max_artifacts}
     }}
  end

  defp feature_spec do
    {:object,
     %{
       "id" => {:string, min: 1, max: 64, no_control: true, non_blank: true},
       "entry_point" => {:nullable, {:string, max: 1_024}},
       "result" => {:enum, @outcomes}
     }}
  end

  defp artifact_spec do
    {:object,
     %{
       "id" => {:string, format: @artifact_id},
       "path" => {:string, min: 1, max: 1_024, no_control: true},
       "content_type" => {:string, format: @mime},
       "size" => {:int, 1},
       "sha256" => {:string, format: @sha256}
     }}
  end

  defp id_errors(value, path) do
    if SetDocument.valid_id?(value),
      do: [],
      else: [{path, "must be a positive integer or a scenario id string"}]
  end

  defp time, do: {:fun, &time_errors/2, :rfc3339}

  defp time_errors(value, path) when is_binary(value) do
    if parse_time(value) == :error, do: [{path, "must be an RFC 3339 time"}], else: []
  end

  defp time_errors(_value, path), do: [{path, "must be a string"}]

  defp parse_time(value) do
    with true <- Regex.match?(@time, value),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}}
    else
      _other -> :error
    end
  end

  defp path, do: {:fun, &path_errors/2, :path}

  defp path_errors(value, path) when is_binary(value) do
    if byte_size(value) in 1..4_096 and not Regex.match?(@control, value) and
         not String.starts_with?(value, "/"),
       do: [],
       else: [{path, "must hold relative paths of 1 to 4096 bytes"}]
  end

  defp path_errors(_value, path), do: [{path, "must hold relative paths of 1 to 4096 bytes"}]

  defp check_sizes(%{"artifacts" => artifacts}) do
    if Enum.any?(artifacts, &(&1["size"] > @max_artifact_bytes)),
      do: {:error, :artifact_too_large},
      else: :ok
  end

  defp cross_errors(body) do
    {:ok, started} = parse_time(body["started_at"])
    {:ok, finished} = parse_time(body["finished_at"])
    artifact_ids = Enum.map(body["artifacts"], & &1["id"])
    declared = MapSet.new(artifact_ids)
    result_ids = Enum.map(body["results"], &SetDocument.id_string(&1["id"]))

    List.flatten([
      if(DateTime.before?(finished, started),
        do: [{["finished_at"], "must not be before started_at"}],
        else: []
      ),
      if(distinct?(artifact_ids), do: [], else: [{["artifacts"], "must not repeat an id"}]),
      if(distinct?(result_ids), do: [], else: [{["results"], "must not repeat a scenario id"}]),
      if(
        Enum.all?(body["results"], fn r ->
          Enum.all?(r["evidence"], &MapSet.member?(declared, &1))
        end),
        do: [],
        else: [{["results"], "evidence must name declared artifacts"}]
      ),
      body |> RunValidator.links_errors() |> cut()
    ])
  end

  defp distinct?(list), do: length(Enum.uniq(list)) == length(list)

  defp columns(body) do
    {:ok, started} = parse_time(body["started_at"])
    {:ok, finished} = parse_time(body["finished_at"])

    %{
      run_id: body["run_id"],
      started_at: started,
      finished_at: finished,
      source_commit: body["source"]["commit"],
      dirty: body["source"]["dirty"],
      scenario_set_digest: body["scenario_set"]["digest"],
      scenario_set_source: body["scenario_set"]["source"],
      merge_result: Map.get(body, "merge_result") != nil
    }
  end

  defp cut(errors) do
    errors
    |> Enum.map(fn {path, message} -> {Enum.take_while(path, &is_binary/1), message} end)
    |> Enum.uniq()
  end
end
