defmodule GoodFlows.ChangeRequests.ClaimsDocument do
  @moduledoc """
  Parses and validates a `change-claims/2` file (design D4).

  `parse/1` reads the YAML front matter with `GoodFlows.FrontMatter`; the
  Markdown body is never parsed.

  `validate/2` checks the ten required keys and their shapes, then the
  three server checks against stored facts: `head` equals the current
  head (which must have Git facts), every `decisions[].path` is a `path` or
  `old_path` of that head's `diff.files`, and every `safe_because[].proof`
  is a known level. `location` and `evidence` references are never
  checked. Any other `format` is a single error on `format`.

  Errors are rendered on front matter paths such as
  `safe_because[0].evidence`; the root is `front_matter`.
  """

  alias GoodFlows.ChangeRequests.Params
  alias GoodFlows.DocumentErrors
  alias GoodFlows.FrontMatter
  alias GoodFlows.ReviewPolicies.Document
  alias GoodFlows.TestReports.Shape

  @format "change-claims/2"
  @doors ~w(one_way two_way)
  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u

  @typedoc "What the front matter is checked against."
  @type context :: %{
          number: pos_integer(),
          head: String.t() | nil,
          diff_paths: MapSet.t(String.t()) | nil
        }

  @doc "The only accepted `format`."
  @spec format() :: String.t()
  def format, do: @format

  @doc "Parses the front matter of a claims file (`GoodFlows.FrontMatter.parse/1`)."
  @spec parse(binary()) :: {:ok, map()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def parse(raw) when is_binary(raw) do
    case FrontMatter.parse(raw) do
      {:ok, front_matter} -> {:ok, front_matter}
      {:error, message} -> {:error, {:invalid_body, %{"front_matter" => [message]}}}
    end
  end

  @doc "Validates parsed front matter against `context`."
  @spec validate(map(), context()) :: :ok | {:error, {:invalid_body, DocumentErrors.errors()}}
  def validate(%{"format" => format}, _context) when format != @format,
    do: {:error, {:invalid_body, %{"format" => ["must be #{@format}"]}}}

  def validate(front_matter, context) do
    errors =
      case Shape.check(front_matter, spec(context), []) do
        [] -> server_errors(front_matter, context)
        errors -> errors
      end

    if errors == [],
      do: :ok,
      else: {:error, {:invalid_body, DocumentErrors.render(errors, "front_matter")}}
  end

  defp spec(context) do
    {:object,
     %{
       "format" => {:enum, [@format]},
       "cr" => {:fun, &cr_errors(&1, &2, context.number), :cr},
       "head" => Params.sha_spec(),
       "door" => {:enum, @doors},
       "door_reason" => nonblank(),
       "reach" => nonblank(),
       "safe_because" => {:list, safe_because_spec(), min: 1, max: 100},
       "left_open" =>
         {:list,
          {:object, %{"risk" => nonblank(), "location" => nonblank(), "affected" => nonblank()}},
          max: 100},
       "questions" =>
         {:list,
          {:object,
           %{
             "id" => nonblank(),
             "text" => nonblank(),
             "options" => {:list, nonblank()},
             "recommendation" => nonblank()
           }}, max: 50},
       "decisions" =>
         {:list,
          {:object,
           %{
             "id" => nonblank(),
             "path" => nonblank(),
             "hunk" => {:string, []},
             "note" => {:string, []}
           }}, max: 3}
     }}
  end

  defp safe_because_spec do
    {:object,
     %{
       "fact" => nonblank(),
       "location" => nonblank(),
       "proof" => {:enum, Document.proof_levels()},
       "evidence" => {:omit, {:fun, &evidence_errors/2, :evidence}},
       "covers" => {:omit, {:fun, &covers_errors/2, :covers}}
     }}
  end

  defp nonblank, do: {:string, min: 1, non_blank: true}

  defp cr_errors(nil, _path, _number), do: []
  defp cr_errors(number, _path, number), do: []

  defp cr_errors(value, path, _number) when is_integer(value),
    do: [{path, "must equal the change request's number"}]

  defp cr_errors(_value, path, _number), do: [{path, "must be an integer or null"}]

  defp evidence_errors(list, path) when is_list(list) and length(list) <= 20 do
    if Enum.all?(list, &reference?/1),
      do: [],
      else: [{path, "must hold relative references of 1 to 1024 bytes"}]
  end

  defp evidence_errors(list, path) when is_list(list),
    do: [{path, "must not have more than 20 entries"}]

  defp evidence_errors(_value, path), do: [{path, "must be an array"}]

  defp reference?(value) when is_binary(value) do
    byte_size(value) in 1..1_024 and not Regex.match?(@control, value) and
      not String.starts_with?(value, "/")
  end

  defp reference?(_value), do: false

  defp covers_errors(%{"capability" => c, "requirement" => r, "scenario" => s} = covers, path)
       when map_size(covers) == 3 do
    if Enum.all?([c, r, s], &(is_binary(&1) and String.trim(&1) != "")),
      do: [],
      else: [{path, "must have a nonempty capability, requirement and scenario"}]
  end

  defp covers_errors(_value, path),
    do: [{path, "must have exactly capability, requirement and scenario"}]

  defp server_errors(front_matter, context) do
    head_errors(front_matter["head"], context) ++
      ran_errors(front_matter["safe_because"]) ++
      unique_id_errors(front_matter["questions"], "questions") ++
      recommendation_errors(front_matter["questions"]) ++
      unique_id_errors(front_matter["decisions"], "decisions") ++
      decision_path_errors(front_matter["decisions"], context.diff_paths)
  end

  defp head_errors(_head, %{diff_paths: nil}),
    do: [{["head"], "must be a head with reported Git facts"}]

  defp head_errors(head, %{head: head}), do: []
  defp head_errors(_head, _context), do: [{["head"], "must equal the change request's head"}]

  defp ran_errors(entries) do
    indexed_errors(entries, fn entry ->
      if entry["proof"] == "ran" and Map.get(entry, "evidence", []) == [],
        do: {"evidence", "is required when proof is ran"}
    end)
    |> Enum.map(fn {index, {key, message}} -> {["safe_because", index, key], message} end)
  end

  defp recommendation_errors(questions) do
    indexed_errors(questions, fn question ->
      if question["recommendation"] not in question["options"], do: :error
    end)
    |> Enum.map(fn {index, :error} ->
      {["questions", index, "recommendation"], "must be one of the options"}
    end)
  end

  defp decision_path_errors(_decisions, nil), do: []

  defp decision_path_errors(decisions, diff_paths) do
    indexed_errors(decisions, fn decision ->
      if not MapSet.member?(diff_paths, decision["path"]), do: :error
    end)
    |> Enum.map(fn {index, :error} ->
      {["decisions", index, "path"], "must be a path in the head's diff"}
    end)
  end

  defp unique_id_errors(entries, key) do
    {errors, _seen} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {entry, index}, {errors, seen} ->
        if MapSet.member?(seen, entry["id"]),
          do: {[{[key, index, "id"], "must be unique"} | errors], seen},
          else: {errors, MapSet.put(seen, entry["id"])}
      end)

    Enum.reverse(errors)
  end

  defp indexed_errors(entries, check) do
    for {entry, index} <- Enum.with_index(entries),
        result = check.(entry),
        result != nil,
        do: {index, result}
  end
end
