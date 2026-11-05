defmodule GoodFlows.TestReportsTest do
  use GoodFlows.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Projects
  alias GoodFlows.Repo
  alias GoodFlows.Spry.{Recipe, Run}
  alias GoodFlows.TestReports
  alias GoodFlows.TestReports.{Document, Report, StorageError, Store, Validator}

  setup do
    account = account_fixture()
    other = account_fixture()
    %{account: account, other: other, project: project_fixture(account)}
  end

  defp count(where) do
    Report |> where(^where) |> Repo.aggregate(:count)
  end

  defp partition(document, partition, count) do
    document
    |> put_at(["report", "partition"], partition)
    |> put_at(["report", "partition_count"], count)
    |> put_at(["report", "records", 0, "partition"], partition)
    |> put_at(["report", "records", 0, "partition_count"], count)
  end

  # Re-encodes `term` with every object's keys in reverse order and decodes
  # it the way the endpoint does.
  defp reorder_keys(term) do
    {:ok, decoded} = term |> reversed_keys() |> Jason.encode!() |> Document.decode()
    decoded
  end

  defp reversed_keys(map) when is_map(map),
    do:
      map
      |> Enum.sort(:desc)
      |> Enum.map(fn {k, v} -> {k, reversed_keys(v)} end)
      |> Jason.OrderedObject.new()

  defp reversed_keys(list) when is_list(list), do: Enum.map(list, &reversed_keys/1)
  defp reversed_keys(other), do: other

  defp postgres_error(pg_code, extra \\ %{}) do
    %Postgrex.Error{
      postgres:
        Map.merge(%{code: nil, pg_code: pg_code, severity: "ERROR", message: "boom"}, extra)
    }
  end

  describe "ingest/4" do
    test "stores a validated report under the account and project", ctx do
      document = report("complete")

      assert {:ok, %{id: id, report_id: "report-1", status: "complete", duplicate: false}} =
               TestReports.ingest(ctx.account, ctx.project, nil, document)

      report = Repo.get!(Report, id)
      assert report.account_id == ctx.account.id
      assert report.project_id == ctx.project.id
      assert report.api_key_id == nil
      assert report.workflow_run_id == document["workflow_run_id"]
      assert report.workflow == "default"
      assert report.environment == "local"
      assert report.job == "test"
      assert report.job_status == "passed"
      assert report.suite_id == document["report"]["suite_id"]
      assert report.partition == "1"
      assert report.partition_count == 3
      assert report.status == "complete"
      assert %DateTime{} = report.inserted_at
    end

    test "the stored payload is the validated body with no project slug", ctx do
      {:ok, %{id: id}} = TestReports.ingest(ctx.account, ctx.project, nil, report("failed"))

      payload = Repo.get!(Report, id).payload
      assert payload == report("failed")
      refute Map.has_key?(payload, "project")
      refute inspect(payload) =~ ctx.project.slug
    end

    test "stored fixtures keep integer microseconds, source, partitions and event order", ctx do
      for name <- names() do
        {:ok, %{id: id}} = TestReports.ingest(ctx.account, ctx.project, nil, report(name))
        payload = Repo.get!(Report, id).payload

        assert payload["source"] == report(name)["source"]
        assert payload["report"]["partition"] == report(name)["report"]["partition"]
        assert payload["report"]["partition_count"] == 3

        assert Enum.map(records(payload), & &1["event"]) ==
                 Enum.map(records(report(name)), & &1["event"])

        for record <- records(payload),
            {key, value} <- record,
            String.ends_with?(key, "_us") and not is_map(value) and value != nil,
            do: assert(is_integer(value), "#{name}: #{key} is not an integer")
      end
    end

    test "records the submitting API key", ctx do
      user = user_fixture()
      account_user = account_user_fixture(ctx.account, user, :member)
      {api_key, _token} = api_key_fixture(account_user, %{type: :private})

      {:ok, %{id: id}} = TestReports.ingest(ctx.account, ctx.project, api_key, report("complete"))
      assert Repo.get!(Report, id).api_key_id == api_key.id
    end

    test "incomplete reports are stored as incomplete", ctx do
      assert {:ok, %{status: "incomplete", duplicate: false}} =
               TestReports.ingest(ctx.account, ctx.project, nil, report("incomplete"))
    end

    test "invalid documents, including a body project, store nothing", ctx do
      assert {:error, {:invalid_test_report, %{"body" => ["has an unknown field"]}}} =
               TestReports.ingest(
                 ctx.account,
                 ctx.project,
                 nil,
                 Map.put(report("complete"), "project", ctx.project.slug)
               )

      assert {:error, {:invalid_test_report, %{"body" => ["has an unknown field"]}}} =
               TestReports.ingest(
                 ctx.account,
                 ctx.project,
                 nil,
                 Map.put(report("complete"), "account_id", ctx.other.id)
               )

      assert count(account_id: ctx.account.id) == 0
    end

    test "a project of another account is refused and nothing is stored", ctx do
      other_project = project_fixture(ctx.other)

      assert TestReports.ingest(ctx.account, other_project, nil, report("complete")) ==
               {:error, :not_found}

      # A forged struct claiming the caller's account still violates the
      # composite foreign key.
      forged = %{other_project | account_id: ctx.account.id}

      assert TestReports.ingest(ctx.account, forged, nil, report("complete")) ==
               {:error, :not_found}

      assert Repo.aggregate(Report, :count) == 0
    end

    test "a project deleted after it was loaded stores nothing", ctx do
      project = project_fixture(ctx.account)
      :ok = Projects.delete_project(ctx.account, project)

      assert TestReports.ingest(ctx.account, project, nil, report("complete")) ==
               {:error, :not_found}

      assert Repo.aggregate(Report, :count) == 0
    end

    test "an API key deleted after authentication is test_report_storage_unavailable, not 404",
         ctx do
      account_user = account_user_fixture(ctx.account, user_fixture(), :member)
      {api_key, _token} = api_key_fixture(account_user, %{type: :private})
      Repo.delete!(api_key)

      assert TestReports.ingest(ctx.account, ctx.project, api_key, report("complete")) ==
               {:error, :test_report_storage_unavailable}

      assert Repo.aggregate(Report, :count) == 0
    end

    test "a foreign key other than the project's is test_report_storage_unavailable", ctx do
      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise %Postgrex.Error{
          postgres: %{
            code: :foreign_key_violation,
            pg_code: "23503",
            severity: "ERROR",
            constraint: "test_reports_account_id_fkey",
            message: "insert or update violates foreign key constraint"
          }
        }
      end)

      assert TestReports.ingest(ctx.account, ctx.project, nil, report("complete")) ==
               {:error, :test_report_storage_unavailable}
    end

    test "the same identity under two projects of one account stores two rows", ctx do
      second = project_fixture(ctx.account)

      {:ok, first_ack} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))
      {:ok, second_ack} = TestReports.ingest(ctx.account, second, nil, report("complete"))

      refute first_ack.id == second_ack.id
      refute second_ack.duplicate
      assert count(account_id: ctx.account.id) == 2
    end

    test "identical identities stay isolated between accounts", ctx do
      other_project = project_fixture(ctx.other, %{"slug" => ctx.project.slug})

      {:ok, mine} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))
      changed = put_at(report("complete"), ["job_status"], "failed")

      # A different body under the same external identity in another account
      # is a new report there, not a conflict revealing the first account's.
      assert {:ok, theirs} = TestReports.ingest(ctx.other, other_project, nil, changed)
      refute theirs.duplicate
      refute theirs.id == mine.id
      assert count(account_id: ctx.other.id) == 1
    end

    test "the row stores the digest of the canonical payload", ctx do
      {:ok, %{id: id}} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))
      %Report{payload: payload, payload_digest: digest} = Repo.get!(Report, id)

      assert byte_size(digest) == 32
      assert digest == Document.digest(payload)
      {:ok, reordered} = Document.normalize(reorder_keys(report("complete")))
      assert digest == Document.digest(reordered)
    end

    test "a partition_count above 2^31 is stored exactly", ctx do
      count = 3_000_000_000
      document = partition(report("complete"), "1", count)

      assert {:ok, %{id: id}} = TestReports.ingest(ctx.account, ctx.project, nil, document)

      report = Repo.get!(Report, id)
      assert report.partition_count == count
      assert report.payload["report"]["partition_count"] == count
    end

    test "independent partitions of one job are stored separately with their identities",
         ctx do
      base = report("complete")

      acks =
        for index <- 1..3 do
          document =
            base
            |> with_report_id("report-#{index}")
            |> partition(Integer.to_string(index), 3)

          assert {:ok, %{duplicate: false} = ack} =
                   TestReports.ingest(ctx.account, ctx.project, nil, document)

          ack
        end

      assert acks |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3

      stored =
        Repo.all(
          from r in Report,
            where: r.project_id == ^ctx.project.id,
            order_by: r.partition,
            select: {r.workflow_run_id, r.suite_id, r.report_id, r.partition, r.partition_count}
        )

      run = base["workflow_run_id"]
      suite = base["report"]["suite_id"]

      assert stored == [
               {run, suite, "report-1", "1", 3},
               {run, suite, "report-2", "2", 3},
               {run, suite, "report-3", "3", 3}
             ]
    end

    test "an interrupted worker is incomplete and keeps its completed timings", ctx do
      complete = report("complete")
      # Drop suite_finished and end on a test that never finished.
      kept = Enum.drop(records(complete), -1)

      dangling =
        kept
        |> Enum.find(&(&1["event"] == "test_started"))
        |> Map.merge(%{"execution_id" => 99, "received_offset_us" => 9_000})

      document = with_records(complete, kept ++ [dangling])
      assert document["report"]["truncated"] == false

      assert {:ok, %{id: id, status: "incomplete"}} =
               TestReports.ingest(ctx.account, ctx.project, nil, document)

      durations =
        for %{"event" => "test_finished", "duration_us" => d} <-
              records(Repo.get!(Report, id).payload),
            do: d

      assert durations ==
               for(%{"event" => "test_finished", "duration_us" => d} <- kept, do: d)

      assert 1500 in durations and 6300 in durations
    end

    test "reports from different runners are stored under the same rules", ctx do
      exunit = report("complete")
      jest = report("failed")

      for document <- [exunit, jest] do
        assert {:ok, %{id: id}} = TestReports.ingest(ctx.account, ctx.project, nil, document)
        payload = Repo.get!(Report, id).payload

        assert payload == document
        assert hd(records(payload))["runner"] == hd(records(document))["runner"]

        for {stored, sent} <- Enum.zip(records(payload), records(document)),
            do: assert(stored["meta"] == sent["meta"])
      end

      assert [%{"name" => "exunit"}, %{"name" => "jest"}] =
               Enum.map([exunit, jest], &hd(records(&1))["runner"])

      assert count(project_id: ctx.project.id) == 2
    end

    test "a retired-format report is rejected and stores nothing", ctx do
      retired =
        report("complete")
        |> Map.put("format", "exunit-timings")
        |> put_at(["report", "records", 0, "format"], "exunit-timings")

      assert TestReports.ingest(ctx.account, ctx.project, nil, retired) ==
               {:error, {:invalid_test_report, %{"format" => ["is invalid"]}}}

      assert count(project_id: ctx.project.id) == 0
    end
  end

  describe "idempotency" do
    test "an exact retry returns the same id as a duplicate and keeps one row", ctx do
      {:ok, first} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))
      {:ok, retry} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))

      assert retry == %{first | duplicate: true}
      assert count(project_id: ctx.project.id) == 1
    end

    test "object key order does not matter for an exact retry", ctx do
      {:ok, first} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))

      {:ok, reordered} =
        report("complete")
        |> Enum.sort(:desc)
        |> Jason.OrderedObject.new()
        |> Jason.encode!()
        |> Document.decode()

      assert {:ok, %{id: id, duplicate: true}} =
               TestReports.ingest(ctx.account, ctx.project, nil, reordered)

      assert id == first.id
    end

    test "a different body under a stored identity is a conflict and changes nothing", ctx do
      {:ok, first} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))
      stored = Repo.get!(Report, first.id)

      variants = [
        Map.put(report("complete"), "job_status", "failed"),
        Map.put(report("complete"), "environment", nil),
        put_at(report("complete"), ["source", "dirty"], true),
        put_at(report("complete"), ["report", "truncated"], true),
        put_at(report("complete"), ["report", "records", 0, "seed"], 1)
      ]

      for variant <- variants do
        assert TestReports.ingest(ctx.account, ctx.project, nil, variant) ==
                 {:error, :test_report_conflict}
      end

      # Different outcomes and durations under the same identity.
      different_results =
        "failed"
        |> report()
        |> with_report_id("report-1")
        |> put_at(["report", "partition"], "1")
        |> put_at(["report", "records", 0, "partition"], "1")

      assert TestReports.ingest(ctx.account, ctx.project, nil, different_results) ==
               {:error, :test_report_conflict}

      assert Repo.get!(Report, first.id) == stored
      assert count(project_id: ctx.project.id) == 1
    end

    test "a stored incomplete report is never replaced by a later complete one", ctx do
      incomplete = report("incomplete")
      {:ok, first} = TestReports.ingest(ctx.account, ctx.project, nil, incomplete)

      later =
        "complete"
        |> report()
        |> with_report_id(incomplete["report"]["report_id"])
        |> put_at(["report", "partition"], "3")
        |> put_at(["report", "records", 0, "partition"], "3")

      assert {:ok, _document, "complete"} = Validator.validate(later)

      assert TestReports.ingest(ctx.account, ctx.project, nil, later) ==
               {:error, :test_report_conflict}

      assert %Report{status: "incomplete", payload: ^incomplete} = Repo.get!(Report, first.id)
    end

    test "nested object key order does not matter; array element order does", ctx do
      {:ok, first} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))

      assert {:ok, %{id: id, duplicate: true}} =
               TestReports.ingest(ctx.account, ctx.project, nil, reorder_keys(report("complete")))

      assert id == first.id

      # `meta` objects are reordered too.
      assert map_size(hd(records(report("complete")))["meta"]) > 1

      # A test's nested `path` (Jest), reversed on both events of each pair.
      failed = report("failed")
      {:ok, _} = TestReports.ingest(ctx.account, ctx.project, nil, failed)

      indexes =
        for {%{"path" => [_, _ | _]}, index} <- Enum.with_index(records(failed)), do: index

      # Two attempts of one retried test, each a started/finished pair.
      assert [_, _, _, _] = indexes

      swapped =
        Enum.reduce(indexes, failed, fn index, document ->
          path = Enum.at(records(document), index)["path"]
          put_at(document, ["report", "records", index, "path"], Enum.reverse(path))
        end)

      assert {:ok, _payload, "complete"} = Validator.validate(swapped)

      assert TestReports.ingest(ctx.account, ctx.project, nil, swapped) ==
               {:error, :test_report_conflict}

      assert count(project_id: ctx.project.id) == 2
    end

    test "a retry that loses the insert is compared by digest, not by payload", ctx do
      {:ok, _} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))

      expect(Store, :one, fn query, opts ->
        refute inspect(query) =~ "GC.AlphaTest"
        call_original(Store, :one, [query, opts])
      end)

      assert {:ok, %{duplicate: true}} =
               TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))
    end
  end

  describe "storage failures" do
    test "a connection error before commit is test_report_storage_unavailable and stores nothing",
         ctx do
      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise DBConnection.ConnectionError, "tcp recv: closed"
      end)

      assert TestReports.ingest(ctx.account, ctx.project, nil, report("complete")) ==
               {:error, :test_report_storage_unavailable}

      assert count(project_id: ctx.project.id) == 0
    end

    test "a statement timeout is test_report_storage_unavailable", ctx do
      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise %Postgrex.Error{
          postgres: %{
            code: :query_canceled,
            pg_code: "57014",
            severity: "ERROR",
            message: "canceling statement due to statement timeout"
          }
        }
      end)

      assert TestReports.ingest(ctx.account, ctx.project, nil, report("complete")) ==
               {:error, :test_report_storage_unavailable}
    end

    test "a failure during the comparison is test_report_storage_unavailable", ctx do
      {:ok, _} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))

      expect(Store, :one, fn _query, _opts -> raise DBConnection.ConnectionError, "timeout" end)

      assert TestReports.ingest(ctx.account, ctx.project, nil, report("complete")) ==
               {:error, :test_report_storage_unavailable}
    end

    test "a lost commit confirmation is unavailable; the exact retry finds the row", ctx do
      expect(Store, :insert_all, fn schema, rows, opts ->
        _committed = call_original(Store, :insert_all, [schema, rows, opts])
        raise DBConnection.ConnectionError, "connection closed before the reply"
      end)

      assert TestReports.ingest(ctx.account, ctx.project, nil, report("complete")) ==
               {:error, :test_report_storage_unavailable}

      [committed] =
        Repo.all(from r in Report, where: r.project_id == ^ctx.project.id, select: r.id)

      assert {:ok, %{id: ^committed, duplicate: true}} =
               TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))

      assert count(project_id: ctx.project.id) == 1
    end

    test "storage queries are not logged and use the configured timeout", ctx do
      timeout = TestReports.db_timeout_ms()

      expect(Store, :insert_all, fn schema, rows, opts ->
        assert opts[:log] == false
        assert opts[:timeout] == timeout
        call_original(Store, :insert_all, [schema, rows, opts])
      end)

      {:ok, _} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))

      expect(Store, :one, fn query, opts ->
        assert opts[:log] == false
        assert opts[:timeout] == timeout
        call_original(Store, :one, [query, opts])
      end)

      {:ok, _} = TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))
    end

    test "transient SQLSTATEs (classes 08, 40, 53, 57, 55P03, 25006) are unavailable", ctx do
      for pg_code <- ~w(08000 08006 40001 40P01 53100 53300 57014 57P01 57P03 55P03 25006) do
        expect(Store, :insert_all, fn _schema, _rows, _opts -> raise postgres_error(pg_code) end)

        assert TestReports.ingest(ctx.account, ctx.project, nil, report("complete")) ==
                 {:error, :test_report_storage_unavailable},
               pg_code
      end

      assert count(project_id: ctx.project.id) == 0
    end

    test "other database errors raise without the Postgres message or payload", ctx do
      sentinel = "SENTINEL-postgres-detail-91c2"

      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise postgres_error("22P05", %{
                message: "unsupported Unicode escape #{sentinel}",
                detail: sentinel,
                constraint: nil
              })
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          error =
            assert_raise StorageError, fn ->
              TestReports.ingest(ctx.account, ctx.project, nil, report("complete"))
            end

          assert Exception.message(error) == "test report storage failed (SQLSTATE 22P05)"
          refute inspect(error) =~ sentinel
        end)

      assert log =~ "SQLSTATE 22P05"
      refute log =~ sentinel
    end

    test "an account deleted between authentication and insert is unavailable", ctx do
      expect(Store, :insert_all, fn schema, rows, opts ->
        Repo.delete!(ctx.account)
        call_original(Store, :insert_all, [schema, rows, opts])
      end)

      assert TestReports.ingest(ctx.account, ctx.project, nil, report("complete")) ==
               {:error, :test_report_storage_unavailable}

      assert Repo.aggregate(Report, :count) == 0
    end
  end

  describe "project deletion" do
    test "a project with a report and no recipes cannot be deleted", ctx do
      %{id: id} = stored_report_fixture(ctx.account, ctx.project)

      assert Projects.delete_project(ctx.account, ctx.project) == {:error, :has_test_reports}
      assert {:ok, _} = Projects.get_project(ctx.account, ctx.project.slug)
      assert Repo.get(Report, id)
    end

    test "a project with recipes still reports has_recipes", ctx do
      recipe_fixture(ctx.project)
      assert Projects.delete_project(ctx.account, ctx.project) == {:error, :has_recipes}

      reports_only = project_fixture(ctx.account)
      stored_report_fixture(ctx.account, reports_only)
      assert Projects.delete_project(ctx.account, reports_only) == {:error, :has_test_reports}

      neither = project_fixture(ctx.account)
      assert Projects.delete_project(ctx.account, neither) == :ok
    end

    test "the database refuses a direct delete of a project with reports", ctx do
      stored_report_fixture(ctx.account, ctx.project)

      assert_raise Postgrex.Error, ~r/test_reports_project_id_fkey/, fn ->
        Repo.query!("DELETE FROM projects WHERE id = $1", [Ecto.UUID.dump!(ctx.project.id)])
      end
    end

    test "deleting the account removes its projects, recipes, runs and reports", ctx do
      recipe = recipe_fixture(ctx.project)
      run = run_fixture(ctx.account, recipe, status: "succeeded")
      %{id: report_id} = stored_report_fixture(ctx.account, ctx.project)

      other_project = project_fixture(ctx.other)
      %{id: other_report_id} = stored_report_fixture(ctx.other, other_project)

      Repo.delete!(ctx.account)

      refute Repo.get(Account, ctx.account.id)
      refute Repo.get(Recipe, recipe.id)
      refute Repo.get(Run, run.id)
      refute Repo.get(Report, report_id)
      assert Repo.get(Report, other_report_id)
    end

    test "the unique identity is enforced by the database", ctx do
      %{id: id} = stored_report_fixture(ctx.account, ctx.project)
      row = Repo.get!(Report, id)

      assert_raise Ecto.ConstraintError,
                   ~r/test_reports_identity_index/,
                   fn ->
                     Repo.insert!(%{row | id: Ecto.UUID.generate()})
                   end
    end
  end
end
