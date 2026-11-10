defmodule GoodFlows.Migrations.CreateWorkflowRunsMigrationTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  @identity_index "workflow_runs_identity_index"
  @list_index "workflow_runs_list_index"
  @workflow_index "workflow_runs_workflow_list_index"
  @graph_index "workflow_runs_workflow_graph_index"
  @commit_index "workflow_runs_commit_list_index"
  @branch_index "workflow_runs_branch_list_index"
  @api_key_index "workflow_runs_api_key_id_index"

  test "workflow_runs has the copied columns and no updated_at" do
    columns = columns()

    assert columns["id"] == %{type: "uuid", precision: nil, nullable: "NO"}
    assert columns["account_id"] == %{type: "uuid", precision: nil, nullable: "NO"}
    assert columns["project_id"] == %{type: "uuid", precision: nil, nullable: "NO"}
    assert columns["api_key_id"] == %{type: "uuid", precision: nil, nullable: "YES"}
    assert columns["run_id"] == %{type: "uuid", precision: nil, nullable: "NO"}
    assert columns["workflow"] == %{type: "text", precision: nil, nullable: "NO"}
    assert columns["environment"] == %{type: "text", precision: nil, nullable: "YES"}
    assert columns["outcome"] == %{type: "text", precision: nil, nullable: "NO"}

    assert columns["started_at"] == %{
             type: "timestamp without time zone",
             precision: 0,
             nullable: "NO"
           }

    assert columns["duration_ms"] == %{type: "bigint", precision: nil, nullable: "NO"}
    assert columns["parallelism"] == %{type: "bigint", precision: nil, nullable: "NO"}
    assert columns["max_in_flight"] == %{type: "bigint", precision: nil, nullable: "NO"}
    assert columns["graph_sha256"] == %{type: "text", precision: nil, nullable: "NO"}
    assert columns["source_commit"] == %{type: "text", precision: nil, nullable: "YES"}
    assert columns["source_dirty"] == %{type: "boolean", precision: nil, nullable: "YES"}
    assert columns["host"] == %{type: "jsonb", precision: nil, nullable: "NO"}
    assert columns["payload"] == %{type: "jsonb", precision: nil, nullable: "NO"}
    assert columns["payload_digest"] == %{type: "bytea", precision: nil, nullable: "NO"}

    assert columns["inserted_at"] == %{
             type: "timestamp without time zone",
             precision: 6,
             nullable: "NO"
           }

    refute Map.has_key?(columns, "updated_at")
    refute Map.has_key?(columns, "parent_run_id")
    refute Map.has_key?(columns, "caller_job")

    # Added by AddEnvelopeColumnsToWorkflowRuns. `graph` stays in `payload`.
    assert columns["source_branch"] == %{type: "text", precision: nil, nullable: "YES"}
    assert columns["ci"] == %{type: "jsonb", precision: nil, nullable: "YES"}
    refute Map.has_key?(columns, "graph")
  end

  test "indexes serve identity, keyset order, workflow, graph, commit, branch, and api key nilify" do
    indexes = indexes()

    assert indexes[@identity_index] =~
             "UNIQUE INDEX #{@identity_index} ON public.workflow_runs USING btree (account_id, project_id, run_id)"

    assert indexes[@list_index] =~
             "(account_id, project_id, started_at DESC, run_id DESC)"

    assert indexes[@workflow_index] =~
             "(account_id, project_id, workflow, started_at DESC, run_id DESC)"

    assert indexes[@graph_index] =~
             "(account_id, project_id, workflow, graph_sha256, started_at DESC, run_id DESC)"

    assert indexes[@commit_index] =~
             "(account_id, project_id, source_commit, started_at DESC, run_id DESC)"

    assert indexes[@branch_index] =~
             "(account_id, project_id, source_branch, started_at DESC, run_id DESC)"

    assert indexes[@api_key_index] =~ "(api_key_id)"

    for definition <- Map.values(indexes) do
      refute definition =~ "environment"
      refute definition =~ "outcome"
      refute definition =~ ~r/\bci\b/
    end
  end

  test "foreign keys cascade from the account, nilify the api key, and block project delete" do
    constraints = constraints()

    assert constraints["workflow_runs_account_id_fkey"] =~
             "FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE"

    assert constraints["workflow_runs_api_key_id_fkey"] =~
             "FOREIGN KEY (api_key_id) REFERENCES api_keys(id) ON DELETE SET NULL"

    assert constraints["workflow_runs_project_id_fkey"] ==
             "FOREIGN KEY (project_id, account_id) REFERENCES projects(id, account_id)"
  end

  test "deleting an account removes its runs and leaves another account's" do
    account = account_fixture()
    project = project_fixture(account)
    other = account_fixture()
    other_project = project_fixture(other)

    insert_run(account, project, "11111111-1111-4111-8111-111111111111")
    insert_run(other, other_project, "22222222-2222-4222-8222-222222222222")

    Repo.delete!(account)

    assert run_count(account.id) == 0
    assert run_count(other.id) == 1
  end

  test "a direct project delete is refused while a run is stored" do
    account = account_fixture()
    project = project_fixture(account)
    insert_run(account, project, "33333333-3333-4333-8333-333333333333")

    assert_raise Postgrex.Error, ~r/workflow_runs_project_id_fkey/, fn ->
      Repo.query!("DELETE FROM projects WHERE id = $1::uuid", [Ecto.UUID.dump!(project.id)])
    end

    assert run_count(account.id) == 1
  end

  defp columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name, data_type, datetime_precision, is_nullable
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'workflow_runs'
      """)

    Map.new(rows, fn [name, type, precision, nullable] ->
      {name, %{type: type, precision: precision, nullable: nullable}}
    end)
  end

  defp indexes do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'workflow_runs'"
      )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp constraints do
    %{rows: rows} =
      Repo.query!("""
      SELECT con.conname, pg_get_constraintdef(con.oid)
      FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
      JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
      WHERE nsp.nspname = 'public' AND rel.relname = 'workflow_runs'
      """)

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp insert_run(account, project, run_id) do
    Repo.query!(
      """
      INSERT INTO workflow_runs (
        id, account_id, project_id, run_id, workflow, outcome, started_at,
        duration_ms, parallelism, max_in_flight, graph_sha256, host, payload,
        payload_digest, inserted_at
      ) VALUES (
        gen_random_uuid(), $1::uuid, $2::uuid, $3::uuid, 'ci', 'passed',
        '2026-11-05 12:00:00', 0, 1, 0,
        'abababababababababababababababababababababababababababababababab',
        '{"os":"linux","arch":"x86_64","logical_cpus":1}'::jsonb,
        '{}'::jsonb, decode($4, 'hex'), clock_timestamp()
      )
      """,
      [
        Ecto.UUID.dump!(account.id),
        Ecto.UUID.dump!(project.id),
        Ecto.UUID.dump!(run_id),
        String.duplicate("ab", 32)
      ]
    )
  end

  defp run_count(account_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM workflow_runs WHERE account_id = $1::uuid", [
        Ecto.UUID.dump!(account_id)
      ])

    count
  end
end
