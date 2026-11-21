defmodule GoodFlows.Migrations.CreateChangeRequestsMigrationTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Projects

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, data_type, is_nullable FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        """,
        [table]
      )

    Map.new(rows, fn [name, type, nullable] -> {name, {type, nullable}} end)
  end

  defp indexes(table) do
    %{rows: rows} =
      Repo.query!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = $1", [table])

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  test "change_requests columns and indexes" do
    columns = columns("change_requests")

    for {name, type} <- [
          {"number", "bigint"},
          {"title", "text"},
          {"links", "jsonb"},
          {"link_tickets", "ARRAY"},
          {"state", "text"},
          {"closed_from_state", "text"},
          {"head", "text"},
          {"merged_verdict_state", "text"},
          {"merged_policy_version", "bigint"},
          {"merged_reasons", "jsonb"},
          {"merged_without_mergeable_verdict", "boolean"}
        ] do
      assert {^type, _} = columns[name], name
    end

    assert indexes("change_requests")["change_requests_project_id_number_index"] =~
             "UNIQUE INDEX change_requests_project_id_number_index ON public.change_requests USING btree (project_id, number)"

    assert columns("projects")["change_request_seq"] == {"bigint", "NO"}
  end

  test "per-head tables are unique on their identity" do
    assert indexes("change_request_git_facts")["change_request_git_facts_identity_index"] =~
             "(change_request_id, head, target_branch)"

    assert indexes("change_request_claims")["change_request_claims_identity_index"] =~
             "(change_request_id, head)"

    assert indexes("review_policy_versions")["review_policy_versions_project_id_version_index"] =~
             "(project_id, version)"

    assert columns("change_request_verdicts")["reasons"] == {"jsonb", "NO"}
    assert columns("change_request_events")["to_state"] == {"text", "NO"}
    assert columns("change_request_claims")["document"] == {"text", "NO"}

    assert indexes("workflow_runs")["workflow_runs_required_workflow_index"] =~
             "(project_id, workflow, source_commit, started_at DESC, run_id DESC)"
  end

  test "the project counter is never reused and review policy versions go with the project" do
    account = account_fixture()
    project = project_fixture(account)

    bump = fn ->
      {1, [n]} =
        Repo.update_all(
          from(p in "projects",
            where: p.id == type(^project.id, :binary_id),
            select: p.change_request_seq
          ),
          inc: [change_request_seq: 1]
        )

      n
    end

    assert [1, 2, 3] == [bump.(), bump.(), bump.()]

    user = user_fixture()
    au = account_user_fixture(account, user, :admin)

    Repo.insert_all("review_policy_versions", [
      %{
        id: Ecto.UUID.bingenerate(),
        project_id: Ecto.UUID.dump!(project.id),
        version: 1,
        previous_version: 0,
        document: %{"format" => "review-policy/1"},
        account_user_id: Ecto.UUID.dump!(au.id),
        inserted_at: DateTime.utc_now()
      }
    ])

    assert :ok = Projects.delete_project(account, project)
    assert Repo.aggregate("review_policy_versions", :count) == 0
  end
end
