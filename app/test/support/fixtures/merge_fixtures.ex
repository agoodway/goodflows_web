defmodule GoodFlows.MergeFixtures do
  @moduledoc """
  HTTP helpers for merge coordination tests: a change request that is
  `open` and `mergeable` at a head, lease acquire, heartbeat and release,
  merge reports, parents, retargets and defects.
  """

  import Phoenix.ConnTest
  import Plug.Conn
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.ReviewFixtures

  @endpoint GoodFlowsWeb.Endpoint

  @doc """
  Creates an `open` change request of `slug` with Git facts and claims for
  `head`, `mergeable` under the default policy, and returns its number.
  Options: `:attrs` (create body), `:merge_base`, `:files`, `:target`.
  """
  def mergeable!(conn, slug, head, opts \\ []) do
    number = create_cr(conn, slug, Keyword.get(opts, :attrs, %{}))["number"]
    _ = conn |> post(cr_path(slug, number, "/ready")) |> json_response(200)
    facts!(conn, slug, number, head, Keyword.take(opts, [:merge_base, :files, :target]))
    claims!(conn, slug, number, head, %{"cr" => number})
    number
  end

  @doc """
  Like `mergeable!/4`, but linked to change `change` with an
  intent set graded at `head` by a passing run, so a lease on a moved base
  turns on the merge-result check. Returns the change request's number.
  """
  def graded_mergeable!(conn, slug, head, change \\ "add-export") do
    number = mergeable!(conn, slug, head, attrs: %{"change_id" => change})

    digest =
      conn
      |> post_json(cr_path(slug, number, "/scenario-sets"), set_body(intent_fm(change)))
      |> json_response(201)
      |> get_in(["data", "digest"])

    conn
    |> post_json(
      "/api/v1/projects/#{slug}/verify-runs",
      run_doc(digest, "intent", head, [result("S1"), result("S2")])
    )
    |> json_response(201)

    number
  end

  @doc "Posts a merge lease acquire for change request `number`; returns the conn."
  def acquire(conn, slug, number, head, base),
    do: post_json(conn, cr_path(slug, number, "/merge-lease"), %{"head" => head, "base" => base})

  @doc "Acquires a lease and returns its `data` (asserting `201`)."
  def acquire!(conn, slug, number, head, base),
    do: conn |> acquire(slug, number, head, base) |> json_response(201) |> Map.fetch!("data")

  @doc "The path of lease `id` of `slug`, plus `suffix`."
  def lease_path(slug, id, suffix \\ ""),
    do: "/api/v1/projects/#{slug}/merge-leases/#{id}#{suffix}"

  @doc "Heartbeats lease `id`; returns the conn."
  def heartbeat(conn, slug, id), do: post(conn, lease_path(slug, id, "/heartbeat"))

  @doc "Releases lease `id`; returns the conn."
  def release(conn, slug, id), do: delete(conn, lease_path(slug, id))

  @doc "Reports change request `number` merged with `merged_commit`; returns the conn."
  def merged(conn, slug, number, merged_commit, extra \\ %{}) do
    body = Map.merge(%{"merged_commit" => merged_commit, "target_branch" => "main"}, extra)
    post_json(conn, cr_path(slug, number, "/merged"), body)
  end

  @doc "Puts `parent` as change request `number`'s parent; returns the conn."
  def put_parent(conn, slug, number, parent),
    do: put_json(conn, cr_path(slug, number, "/parent"), %{"number" => parent})

  @doc "Retargets change request `number` to `branch`; returns the conn."
  def retarget(conn, slug, number, branch),
    do: post_json(conn, cr_path(slug, number, "/retarget"), %{"target_branch" => branch})

  @doc "The defects path of `slug`."
  def defects_path(slug), do: "/api/v1/projects/#{slug}/defects"

  @doc "Posts a defect; returns the conn."
  def post_defect(conn, slug, body), do: post_json(conn, defects_path(slug), body)

  @doc "The calibration path of `slug`."
  def calibration_path(slug), do: "/api/v1/projects/#{slug}/calibration"

  @doc "The reasons of verdict `data` with rule `rule`."
  def reasons(verdict, rule), do: Enum.filter(verdict["reasons"], &(&1["rule"] == rule))

  @doc "The rules of verdict `data`."
  def rules(verdict), do: Enum.map(verdict["reasons"], & &1["rule"])

  @doc "Sets the JSON `accept` header to `value`."
  def accept(conn, value), do: put_req_header(conn, "accept", value)
end
