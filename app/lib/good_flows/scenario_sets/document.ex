defmodule GoodFlows.ScenarioSets.Document do
  @moduledoc """
  Validates a scenario set upload: a JSON body of exactly `content` (the
  `qa-scenarios/2` Markdown file) and `sections` (`{id, sha256}` per
  scenario), design D1 and D2.

  Only the YAML front matter of `content` is read (`GoodFlows.FrontMatter`).
  It must have `format` `qa-scenarios/2` (any other is one error on
  `content.format`), `source` `intent` or `diff`, `scenarios`, and may
  have `review`. Intent sets add `change`, `specs` and optional
  `coverage`; diff sets add `branch`, `base`, `revision` and optional
  `regressions`. A key not allowed for the source is `has an unknown
  field` on `content`. Key order is never checked.

  A front matter carrying run results (a top-level `run`, or a scenario
  `result`, `failed_step`, `evidence` or `reason`) is refused on `content`:
  results belong in a verify run.

  Scenario IDs are a positive integer or a string; their string form
  (decimal for an integer) must match `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`
  and is what is stored and compared: in `sections`, coverage rows,
  verify-run results and verdict subjects.

  Errors are fixed messages keyed by path, cut at the first list index
  (`content.scenarios`, `content.coverage`, `sections`), so no submitted
  value is echoed.
  """

  alias GoodFlows.DocumentErrors
  alias GoodFlows.FrontMatter
  alias GoodFlows.TestReports.Shape

  @format "qa-scenarios/2"
  @priorities ~w(must should could)
  @statuses ~w(covered no_check)
  @result_keys ~w(result failed_step evidence reason)
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @short_sha ~r/\A[0-9a-f]{7,64}\z/
  @max_scenarios 200
  @max_covers 100
  @max_coverage 1_000
  @max_regressions 200
  @run_results "must not hold run results; results belong in a verify run"

  @typedoc "A validated upload: the raw content, its front matter and sections."
  @type upload :: %{
          content: String.t(),
          source: String.t(),
          front_matter: map(),
          sections: [%{String.t() => String.t()}]
        }

  @doc "The only accepted `format`."
  @spec format() :: String.t()
  def format, do: @format

  @doc """
  The string form of a scenario ID: a positive integer in decimal, or a
  string as given. Anything else is nil.
  """
  @spec id_string(term()) :: String.t() | nil
  def id_string(id) when is_integer(id) and id > 0, do: Integer.to_string(id)
  def id_string(id) when is_binary(id), do: id
  def id_string(_id), do: nil

  @doc "Whether `id` is a valid scenario ID (see the module documentation)."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) do
    case id_string(id) do
      nil -> false
      string -> Regex.match?(@id, string)
    end
  end

  @doc """
  Validates a normalized upload body. Returns the content, its source,
  the front matter with scenario IDs in string form and the sections with
  string IDs, or `{:invalid_body, errors}`.
  """
  @spec validate(term()) :: {:ok, upload()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def validate(body) do
    spec =
      {:object,
       %{
         "content" => {:string, []},
         "sections" =>
           {:list, {:object, %{"id" => id_spec(), "sha256" => {:string, format: @sha256}}},
            max: @max_scenarios}
       }}

    with [] <- Shape.check(body, spec, []) |> cut(),
         {:ok, front_matter} <- FrontMatter.parse(body["content"]),
         [] <- front_matter_errors(front_matter),
         [] <- section_errors(front_matter, body["sections"]) do
      {:ok,
       %{
         content: body["content"],
         source: front_matter["source"],
         front_matter: stringify(front_matter),
         sections:
           Enum.map(body["sections"], &%{"id" => id_string(&1["id"]), "sha256" => &1["sha256"]})
       }}
    else
      {:error, message} -> invalid(%{"content" => [message]})
      errors when is_list(errors) -> invalid(DocumentErrors.render(errors))
    end
  end

  defp invalid(errors), do: {:error, {:invalid_body, errors}}

  defp front_matter_errors(%{"format" => @format} = front_matter) do
    cond do
      run_results?(front_matter) ->
        [{["content"], @run_results}]

      front_matter["source"] == "intent" ->
        intent_errors(front_matter)

      front_matter["source"] == "diff" ->
        diff_errors(front_matter)

      Map.has_key?(front_matter, "source") ->
        [{["content", "source"], "is invalid"}]

      true ->
        [{["content", "source"], "is required"}]
    end
  end

  defp front_matter_errors(%{"format" => _other}),
    do: [{["content", "format"], "must be #{@format}"}]

  defp front_matter_errors(_front_matter), do: [{["content", "format"], "is required"}]

  defp run_results?(front_matter) do
    Map.has_key?(front_matter, "run") or
      (is_list(front_matter["scenarios"]) and
         Enum.any?(front_matter["scenarios"], fn scenario ->
           is_map(scenario) and Enum.any?(@result_keys, &Map.has_key?(scenario, &1))
         end))
  end

  defp intent_errors(front_matter) do
    spec =
      {:object,
       Map.merge(common_fields(:intent), %{
         "change" => {:string, min: 1, max: 255, no_control: true},
         "specs" => {:fun, &specs_errors/2, :specs},
         "coverage" => {:omit, {:list, coverage_row_spec(), max: @max_coverage}}
       })}

    case content_errors(front_matter, spec) do
      [] -> duplicate_id_errors(front_matter) ++ coverage_errors(front_matter)
      errors -> errors
    end
  end

  defp diff_errors(front_matter) do
    spec =
      {:object,
       Map.merge(common_fields(:diff), %{
         "branch" => {:string, min: 1, max: 255},
         "base" => {:string, min: 1, max: 255},
         "revision" => {:string, format: @short_sha},
         "regressions" => {:omit, {:list, chars(1, 1_000), max: @max_regressions}}
       })}

    case content_errors(front_matter, spec) do
      [] -> duplicate_id_errors(front_matter)
      errors -> errors
    end
  end

  defp content_errors(front_matter, spec),
    do:
      front_matter
      |> Shape.check(spec, [])
      |> Enum.map(fn {p, m} -> {["content" | p], m} end)
      |> cut()

  defp common_fields(source) do
    scenario =
      %{"id" => id_spec(), "name" => chars(1, 200), "priority" => {:enum, @priorities}}
      |> then(&if source == :intent, do: Map.put(&1, "covers", {:omit, covers_spec()}), else: &1)

    %{
      "format" => {:enum, [@format]},
      "source" => {:enum, ["intent", "diff"]},
      "review" => {:optional, {:nullable, {:string, min: 1, max: 2_048}}},
      "scenarios" => {:list, {:object, scenario}, min: 1, max: @max_scenarios}
    }
  end

  defp coverage_row_spec do
    {:object,
     %{
       "capability" => chars(1, 200),
       "requirement" => chars(1, 200),
       "scenario" => chars(1, 200),
       "status" => {:enum, @statuses},
       "scenarios" => {:list, id_spec(), max: @max_scenarios},
       "reason" => {:optional, {:nullable, chars(0, 1_000)}}
     }}
  end

  defp covers_spec, do: {:fun, &covers_errors/2, :covers}

  defp covers_errors(list, path)
       when is_list(list) and list != [] and length(list) <= @max_covers do
    if Enum.all?(list, &cover?/1),
      do: [],
      else: [
        {path, "must hold capability, requirement and exactly one of scenario or implied: true"}
      ]
  end

  defp covers_errors(list, path) when is_list(list),
    do: [{path, "must have 1 to #{@max_covers} entries"}]

  defp covers_errors(_value, path), do: [{path, "must be an array"}]

  defp cover?(%{"capability" => c, "requirement" => r} = cover) do
    names_ok? = Enum.all?([c, r], &chars?(&1, 1, 200))

    case Map.drop(cover, ["capability", "requirement"]) do
      %{"scenario" => s} = rest when map_size(rest) == 1 -> names_ok? and chars?(s, 1, 200)
      %{"implied" => true} = rest when map_size(rest) == 1 -> names_ok?
      _other -> false
    end
  end

  defp cover?(_cover), do: false

  defp specs_errors("uncommitted", _path), do: []

  defp specs_errors(value, path) when is_binary(value) do
    if Regex.match?(@short_sha, value),
      do: [],
      else: [{path, "must be uncommitted or 7 to 64 lowercase hex characters"}]
  end

  defp specs_errors(_value, path), do: [{path, "must be a string"}]

  defp id_spec, do: {:fun, &id_errors/2, :scenario_id}

  defp id_errors(value, path) when is_integer(value) or is_binary(value) do
    if valid_id?(value),
      do: [],
      else: [
        {path, "must be a positive integer or a string matching [A-Za-z0-9][A-Za-z0-9._-]{0,63}"}
      ]
  end

  defp id_errors(_value, path), do: [{path, "must be a positive integer or a string"}]

  defp chars(min, max), do: {:fun, &chars_errors(&1, &2, min, max), :chars}

  defp chars_errors(value, path, min, max) do
    if chars?(value, min, max),
      do: [],
      else: [{path, "must be a string of #{min} to #{max} characters"}]
  end

  defp chars?(value, min, max),
    do: is_binary(value) and String.valid?(value) and String.length(value) in min..max

  # Scenario IDs are unique in string form, so `1` and `"1"` collide.
  defp duplicate_id_errors(front_matter) do
    ids = scenario_ids(front_matter)

    if length(Enum.uniq(ids)) == length(ids),
      do: [],
      else: [{["content", "scenarios"], "must not repeat a scenario id"}]
  end

  defp coverage_errors(%{"coverage" => rows} = front_matter) do
    ids = MapSet.new(scenario_ids(front_matter))
    keys = Enum.map(rows, &{&1["capability"], &1["requirement"], &1["scenario"]})

    row_errors =
      Enum.flat_map(rows, fn row ->
        row_ids = Enum.map(row["scenarios"], &id_string/1)

        cond do
          row["status"] == "covered" and row_ids == [] ->
            ["a covered row must name at least one scenario"]

          row["status"] == "no_check" and row_ids != [] ->
            ["a no_check row must name no scenarios"]

          not Enum.all?(row_ids, &MapSet.member?(ids, &1)) ->
            ["must name scenarios of the set"]

          true ->
            []
        end
      end)

    unique_errors =
      if length(Enum.uniq(keys)) == length(keys),
        do: [],
        else: ["must not repeat a capability, requirement and scenario"]

    (row_errors ++ unique_errors) |> Enum.uniq() |> Enum.map(&{["content", "coverage"], &1})
  end

  defp coverage_errors(_front_matter), do: []

  defp section_errors(front_matter, sections) do
    ids = Enum.map(sections, &id_string(&1["id"]))

    if Enum.sort(ids) == Enum.sort(scenario_ids(front_matter)) and
         length(Enum.uniq(ids)) == length(ids),
       do: [],
       else: [{["sections"], "must have exactly one entry for each scenario id"}]
  end

  defp scenario_ids(front_matter), do: Enum.map(front_matter["scenarios"], &id_string(&1["id"]))

  defp stringify(front_matter) do
    front_matter
    |> Map.update!("scenarios", fn scenarios ->
      Enum.map(scenarios, &Map.update!(&1, "id", fn id -> id_string(id) end))
    end)
    |> then(fn
      %{"coverage" => rows} = fm ->
        %{
          fm
          | "coverage" =>
              Enum.map(
                rows,
                &Map.update!(&1, "scenarios", fn s -> Enum.map(s, fn id -> id_string(id) end) end)
              )
        }

      fm ->
        fm
    end)
  end

  defp cut(errors) do
    errors
    |> Enum.map(fn {path, message} -> {Enum.take_while(path, &is_binary/1), message} end)
    |> Enum.uniq()
  end

  @doc "The set digest: the lowercase hex SHA-256 of the raw `content` bytes."
  @spec digest(String.t()) :: String.t()
  def digest(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
end
