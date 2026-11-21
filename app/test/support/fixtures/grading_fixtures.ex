defmodule GoodFlows.GradingFixtures do
  @moduledoc """
  Builders for grading tests: `qa-scenarios/2` scenario set uploads,
  `verify-run/1` documents and feature index syncs.
  """

  @doc "A scenario entry."
  def scenario(id, priority \\ "must", extra \\ %{}),
    do: Map.merge(%{"id" => id, "name" => "Scenario #{id}", "priority" => priority}, extra)

  @doc "Intent front matter for OpenSpec change `change`."
  def intent_fm(change, scenarios \\ [scenario("S1"), scenario("S2", "should")], extra \\ %{}) do
    Map.merge(
      %{
        "format" => "qa-scenarios/2",
        "source" => "intent",
        "review" => nil,
        "change" => change,
        "specs" => "uncommitted",
        "scenarios" => scenarios
      },
      extra
    )
  end

  @doc "Diff front matter naming `revision`."
  def diff_fm(revision, scenarios \\ [scenario("D1")], extra \\ %{}) do
    Map.merge(
      %{
        "format" => "qa-scenarios/2",
        "source" => "diff",
        "branch" => "feat/x",
        "base" => "main",
        "revision" => revision,
        "scenarios" => scenarios
      },
      extra
    )
  end

  @doc "A set file whose front matter is `fm` (as JSON flow YAML)."
  def set_content(fm, body \\ "# QA scenarios\n"),
    do: "---\n" <> Jason.encode!(fm) <> "\n---\n" <> body

  @doc "A section digest for scenario `id` (with `salt` to change it)."
  def section_sha(id, salt \\ ""),
    do: :sha256 |> :crypto.hash("#{id}#{salt}") |> Base.encode16(case: :lower)

  @doc """
  An upload body for front matter `fm`. Options: `:body` (Markdown body),
  `:salts` (map of scenario id to section salt).
  """
  def set_body(fm, opts \\ []) do
    salts = Keyword.get(opts, :salts, %{})

    %{
      "content" => set_content(fm, Keyword.get(opts, :body, "# QA scenarios\n")),
      "sections" =>
        Enum.map(fm["scenarios"], fn s ->
          id = to_string(s["id"])
          %{"id" => s["id"], "sha256" => section_sha(id, Map.get(salts, id, ""))}
        end)
    }
  end

  @doc "The digest of an upload body."
  def digest_of(body), do: :sha256 |> :crypto.hash(body["content"]) |> Base.encode16(case: :lower)

  @doc "A result entry."
  def result(id, outcome \\ "passed", evidence \\ []),
    do: %{
      "id" => id,
      "result" => outcome,
      "failed_step" => if(outcome == "failed", do: "step 2"),
      "reason" => if(outcome == "passed", do: nil, else: "it broke"),
      "evidence" => evidence
    }

  @doc """
  A `verify-run/1` document grading set `digest` (`source`) on `commit`
  with `results`. Options: `:run_id`, `:finished_at`, `:dirty`,
  `:features`, `:artifacts`, `:merge_result`, `:links`.
  """
  def run_doc(digest, source, commit, results, opts \\ []) do
    finished = Keyword.get(opts, :finished_at, "2026-11-20T10:00:00Z")

    base = %{
      "format" => "verify-run/1",
      "run_id" => Keyword.get(opts, :run_id, Ecto.UUID.generate()),
      "started_at" => Keyword.get(opts, :started_at, "2026-11-20T09:00:00Z"),
      "finished_at" => finished,
      "source" => %{
        "commit" => commit,
        "branch" => "feat/x",
        "dirty" => Keyword.get(opts, :dirty, false),
        "changed_files" => ["lib/a.ex"]
      },
      "scenario_set" => %{"digest" => digest, "source" => source},
      "results" => results,
      "features" => Keyword.get(opts, :features, []),
      "drift" => [],
      "artifacts" => Keyword.get(opts, :artifacts, [])
    }

    Enum.reduce([:merge_result, :links, :workflow_run_id], base, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Map.put(acc, Atom.to_string(key), value)
        :error -> acc
      end
    end)
  end

  @doc "An artifact declaration for `bytes`."
  def artifact(id, bytes, content_type \\ "image/png"),
    do: %{
      "id" => id,
      "path" => "shots/#{id}.png",
      "content_type" => content_type,
      "size" => byte_size(bytes),
      "sha256" => :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    }

  @doc "A feature entry for a sync."
  def feature(id, paths), do: %{"id" => id, "title" => "Feature #{id}", "paths" => paths}
end
