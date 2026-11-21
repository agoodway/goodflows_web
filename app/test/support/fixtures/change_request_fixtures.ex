defmodule GoodFlows.ChangeRequestFixtures do
  @moduledoc """
  Builders for change request tests: SHAs, `git-facts/1` documents,
  `change-claims/2` files and HTTP helpers for the change request API.
  """

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint GoodFlowsWeb.Endpoint

  @doc "A deterministic 40-hex SHA for `n`."
  def sha(n) when is_integer(n),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")

  @doc "A file entry."
  def file(path, attrs \\ %{}) do
    Map.merge(
      %{"path" => path, "status" => "modified", "additions" => 1, "deletions" => 0},
      Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    )
  end

  @doc """
  A valid `git-facts/1` document for `head`. Options: `:target`
  (default `main`), `:merge_base` (default `sha(0)`), `:files` (the diff
  and the single commit's changed files).
  """
  def git_facts(head, opts \\ []) do
    files = Keyword.get(opts, :files, [file("lib/a.ex")])
    merge_base = Keyword.get(opts, :merge_base, sha(0))

    %{
      "format" => "git-facts/1",
      "head" => head,
      "target" => %{"branch" => Keyword.get(opts, :target, "main"), "merge_base" => merge_base},
      "commits" => [%{"sha" => head, "parents" => [merge_base], "changed_files" => files}],
      "diff" => %{"files" => files}
    }
  end

  @doc "Default front matter for `head`, merged with `overrides`."
  def front_matter(head, overrides \\ %{}) do
    Map.merge(
      %{
        "format" => "change-claims/2",
        "cr" => nil,
        "head" => head,
        "door" => "two_way",
        "door_reason" => "Reverting the commit undoes it",
        "reach" => "Only the change request API",
        "safe_because" => [
          %{
            "fact" => "Numbers are per project",
            "location" => "app/lib/good_flows/change_requests.ex:1",
            "proof" => "ran",
            "evidence" => ["app/test/good_flows/change_requests_test.exs:1"]
          }
        ],
        "left_open" => [],
        "questions" => [],
        "decisions" => []
      },
      overrides
    )
  end

  @doc "A claims file whose YAML front matter is `front_matter` (as JSON flow YAML)."
  def claims(front_matter, body \\ "# What changed\n\nA change.\n"),
    do: "---\n" <> Jason.encode!(front_matter) <> "\n---\n" <> body

  @doc """
  A valid workflow-run upload document for `workflow` on `commit` with
  `outcome` (`passed`, `failed` or `cancelled`). Options: `:started_at`,
  `:dirty`.
  """
  def run_document(commit, outcome, opts \\ []) do
    results =
      if outcome == "failed",
        do: [
          %{
            "name" => "test",
            "status" => "failed",
            "exit_code" => 1,
            "command" => "mix test",
            "error" => "exited with 1",
            "duration_ms" => 1,
            "started" => true,
            "blocked_ms" => 0,
            "queued_ms" => 0
          }
        ],
        else: []

    source =
      case Keyword.fetch(opts, :dirty) do
        {:ok, dirty} -> %{"commit" => commit, "dirty" => dirty}
        :error -> %{"commit" => commit}
      end

    %{
      "schema_version" => 1,
      "workflow" => Keyword.get(opts, :workflow, "ci"),
      "run_id" => Ecto.UUID.generate(),
      "started_at" => Keyword.get(opts, :started_at, "2026-11-05T12:00:00Z"),
      "outcome" => outcome,
      "duration_ms" => 0,
      "parallelism" => 1,
      "graph_sha256" => String.duplicate("ab", 32),
      "max_in_flight" => 0,
      "host" => %{"os" => "linux", "arch" => "x86_64", "logical_cpus" => 1},
      "source" => source,
      "results" => results
    }
  end

  @doc "Posts JSON (encoded unless a binary) to `path`."
  def post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  @doc "Puts JSON to `path`."
  def put_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put(path, if(is_binary(body), do: body, else: Jason.encode!(body)))
  end

  @doc "Posts a Markdown claims file to `path`."
  def post_markdown(conn, path, body, content_type \\ "text/markdown") do
    conn
    |> put_req_header("content-type", content_type)
    |> post(path, body)
  end

  @doc "The change requests path of `slug`."
  def crs_path(slug), do: "/api/v1/projects/#{slug}/change-requests"

  @doc "The path of change request `number` of `slug`, plus `suffix`."
  def cr_path(slug, number, suffix \\ ""),
    do: "/api/v1/projects/#{slug}/change-requests/#{number}#{suffix}"

  @doc "Creates a change request through the API and returns its `data`."
  def create_cr(conn, slug, attrs \\ %{}) do
    body = Map.merge(%{"title" => "Add login", "source_branch" => "feat/login"}, attrs)
    conn |> post_json(crs_path(slug), body) |> json_response(201) |> Map.fetch!("data")
  end
end
