defmodule GoodFlows.ChangeRequests.SchemasTest do
  use ExUnit.Case, async: true

  alias GoodFlows.ChangeRequests.{ChangeRequest, Claims, Event, GitFacts, Verdict}
  alias GoodFlows.ReviewPolicies.Version

  test "changesets keep submitted values exactly" do
    title = "  Add login\u00A0 "
    links = %{"tickets" => ["GOO-1"], "threads" => ["https://ampcode.com/threads/T-1"]}

    cs =
      ChangeRequest.create_changeset(%ChangeRequest{number: 1, state: "draft"}, %{
        title: title,
        source_branch: " feat ",
        target_branch: "main",
        change_id: nil,
        links: links
      })

    assert cs.valid?
    assert Ecto.Changeset.get_change(cs, :title) == title
    assert Ecto.Changeset.get_change(cs, :source_branch) == " feat "
    assert Ecto.Changeset.get_change(cs, :links) == links
    assert Ecto.Changeset.get_change(cs, :link_tickets) == ["goo-1"]

    raw = "---\na: 1\n---\r\n body  "

    claims =
      Claims.changeset(%Claims{}, %{
        change_request_id: "x",
        head: "h",
        document: raw,
        front_matter: %{},
        digest: <<1>>
      })

    assert Ecto.Changeset.get_change(claims, :document) == raw

    document = %{"b" => 1, "a" => [3, 2]}

    facts =
      GitFacts.changeset(%GitFacts{}, %{
        change_request_id: "x",
        head: "h",
        target_branch: "main",
        document: document,
        digest: <<1>>
      })

    assert Ecto.Changeset.get_change(facts, :document) == document

    version =
      Version.changeset(%Version{}, %{
        project_id: "p",
        version: 1,
        previous_version: 0,
        document: document,
        note: " n "
      })

    assert Ecto.Changeset.get_change(version, :note) == " n "

    assert Event.changeset(%Event{}, %{
             change_request_id: "x",
             from_state: "draft",
             to_state: "open"
           }).valid?
  end

  test "closing remembers the state, reopening clears it" do
    open = %ChangeRequest{state: "open"}

    assert %{state: "closed", closed_from_state: "open"} =
             Ecto.Changeset.apply_changes(ChangeRequest.state_changeset(open, "closed"))

    closed = %ChangeRequest{state: "closed", closed_from_state: "open"}

    assert %{state: "open", closed_from_state: nil} =
             Ecto.Changeset.apply_changes(ChangeRequest.state_changeset(closed, "open"))
  end

  test "verdict states are checked and reasons may be any JSON array" do
    attrs = %{
      change_request_id: "x",
      state: "mergeable",
      policy_version: 0,
      reasons: [],
      inputs: %{}
    }

    assert Verdict.changeset(%Verdict{}, attrs).valid?
    refute Verdict.changeset(%Verdict{}, %{attrs | state: "approved"}).valid?
  end
end
