defmodule GoodFlows.ReviewFixtures do
  @moduledoc """
  HTTP helpers for review tests: writing a policy, reporting facts and
  claims, reading the packet, answering items and reading events.
  """

  import Phoenix.ConnTest
  import GoodFlows.ChangeRequestFixtures

  @endpoint GoodFlowsWeb.Endpoint

  @doc "Writes policy `settings` as the next version after `previous`."
  def policy!(conn, slug, settings, previous \\ 0, note \\ nil) do
    body = %{
      "previous_version" => previous,
      "policy" => Map.merge(%{"format" => "review-policy/1"}, settings)
    }

    body = if note, do: Map.put(body, "note", note), else: body

    conn |> put_json("/api/v1/projects/#{slug}/review-policy", body) |> json_response(201)
  end

  @doc "Reports Git facts for `head` (status 200 or 201)."
  def facts!(conn, slug, number, head, opts \\ []) do
    conn = post_json(conn, cr_path(slug, number, "/git-facts"), git_facts(head, opts))
    assert_status!(conn, [200, 201])
  end

  @doc "Uploads claims for `head` with front matter `overrides`."
  def claims!(conn, slug, number, head, overrides \\ %{}) do
    conn
    |> post_markdown(cr_path(slug, number, "/claims"), claims(front_matter(head, overrides)))
    |> assert_status!([200, 201])
  end

  @doc "Reads the packet's `data`."
  def packet(conn, slug, number),
    do: conn |> get(cr_path(slug, number, "/review")) |> json_response(200) |> Map.fetch!("data")

  @doc "The items of `packet` of `kind`."
  def items(packet, kind), do: Enum.filter(packet["items"], &(&1["kind"] == kind))

  @doc "The only item of `packet` of `kind`."
  def item!(packet, kind) do
    [item] = items(packet, kind)
    item
  end

  @doc "Posts an answer to item `item_id`; returns the conn."
  def answer(conn, slug, number, item_id, body),
    do: post_json(conn, cr_path(slug, number, "/review/items/#{item_id}/answers"), body)

  @doc "Reads the verdict's `data`."
  def verdict(conn, slug, number),
    do: conn |> get(cr_path(slug, number, "/verdict")) |> json_response(200) |> Map.fetch!("data")

  @doc "Reads events of `slug` with query `params`; returns the body."
  def events(conn, slug, params \\ %{}),
    do: conn |> get("/api/v1/projects/#{slug}/events", params) |> json_response(200)

  defp assert_status!(conn, statuses) do
    unless conn.status in statuses do
      raise "unexpected status #{conn.status}: #{conn.resp_body}"
    end

    Jason.decode!(conn.resp_body)
  end
end
