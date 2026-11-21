defmodule GoodFlows.WorkflowRunsTest do
  use GoodFlows.DataCase, async: true
  use Mimic

  setup :verify_on_exit!

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures

  alias GoodFlows.JsonDocument
  alias GoodFlows.Projects
  alias GoodFlows.Repo
  alias GoodFlows.WorkflowRuns
  alias GoodFlows.WorkflowRuns.{Run, StorageError, Store}

  @other_run_id "22222222-2222-4222-8222-222222222222"
  @above_int32 3_000_000_000

  setup do
    account = account_fixture()
    other = account_fixture()
    %{account: account, other: other, project: project_fixture(account)}
  end

  defp count(where) do
    Run |> where(^where) |> Repo.aggregate(:count)
  end

  defp reorder_keys(term) do
    {:ok, decoded} = term |> reversed_keys() |> Jason.encode!() |> JsonDocument.decode()
    decoded
  end

  defp reversed_keys(map) when is_map(map) do
    map
    |> Enum.sort(:desc)
    |> Enum.map(fn {key, value} -> {key, reversed_keys(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp reversed_keys(list) when is_list(list), do: Enum.map(list, &reversed_keys/1)
  defp reversed_keys(other), do: other

  defp postgres_error(pg_code, extra \\ %{}) do
    %Postgrex.Error{
      postgres:
        Map.merge(%{code: nil, pg_code: pg_code, severity: "ERROR", message: "boom"}, extra)
    }
  end

  describe "ingest/4" do
    test "stores the validated document and the copied columns", ctx do
      document = full()

      assert {:ok, %{id: id, run_id: run_id, duplicate: false}} =
               WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)

      assert run_id == document["run_id"]

      run = Repo.get!(Run, id)
      assert run.account_id == ctx.account.id
      assert run.project_id == ctx.project.id
      assert run.api_key_id == nil
      assert run.run_id == document["run_id"]
      assert run.workflow == "ci"
      assert run.environment == "ci"
      assert run.outcome == "passed"
      assert run.started_at == ~U[2026-11-05 12:00:03Z]
      assert run.duration_ms == 1200
      assert run.parallelism == 4
      assert run.max_in_flight == 2
      assert run.graph_sha256 == document["graph_sha256"]
      assert run.source_commit == document["source"]["commit"]
      assert run.source_dirty == true
      assert run.host == document["host"]
      assert run.payload == document
      refute Map.has_key?(run.payload, "project")
      assert byte_size(run.payload_digest) == 32
      assert run.payload_digest == JsonDocument.digest(document)
      assert %DateTime{} = run.inserted_at
      refute Map.has_key?(Map.from_struct(run), :updated_at)
    end

    test "an omitted source and environment stay null, and dirty false is stored", ctx do
      assert {:ok, %{id: id}} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())
      run = Repo.get!(Run, id)
      assert run.environment == nil
      assert run.source_commit == nil
      assert run.source_dirty == nil
      refute Map.has_key?(run.host, "mem_total_bytes")

      document =
        minimal()
        |> Map.put("run_id", @other_run_id)
        |> Map.put("source", %{"commit" => String.duplicate("cd", 20), "dirty" => false})

      assert {:ok, %{id: dirty_id}} =
               WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)

      stored = Repo.get!(Run, dirty_id)
      assert stored.source_dirty == false
      assert stored.source_commit == String.duplicate("cd", 20)
    end

    test "integers above 2^31 - 1 are stored exactly", ctx do
      document =
        minimal()
        |> Map.put("duration_ms", @above_int32)
        |> Map.put("parallelism", @above_int32)
        |> Map.put("max_in_flight", @above_int32)

      assert {:ok, %{id: id}} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)
      run = Repo.get!(Run, id)
      assert run.duration_ms == @above_int32
      assert run.parallelism == @above_int32
      assert run.max_in_flight == @above_int32
    end

    test "records the submitting API key and nilifies it when the key is deleted", ctx do
      account_user = account_user_fixture(ctx.account, user_fixture(), :member)
      {api_key, _token} = api_key_fixture(account_user, %{type: :private})

      {:ok, %{id: id}} = WorkflowRuns.ingest(ctx.account, ctx.project, api_key, minimal())
      assert Repo.get!(Run, id).api_key_id == api_key.id

      Repo.delete!(api_key)
      assert Repo.get!(Run, id).api_key_id == nil
    end

    test "invalid documents, including an invalid upload envelope, store nothing", ctx do
      assert {:error, {:invalid_workflow_run, %{"graph" => ["has an unknown field"]}}} =
               WorkflowRuns.ingest(
                 ctx.account,
                 ctx.project,
                 nil,
                 Map.put(minimal(), "graph", %{"sha256" => "nope"})
               )

      assert count(project_id: ctx.project.id) == 0
    end

    test "a project of another account stores nothing", ctx do
      other_project = project_fixture(ctx.other)

      assert WorkflowRuns.ingest(ctx.account, other_project, nil, minimal()) ==
               {:error, :not_found}

      forged = %{other_project | account_id: ctx.account.id}

      assert WorkflowRuns.ingest(ctx.account, forged, nil, minimal()) == {:error, :not_found}
      assert Repo.aggregate(Run, :count) == 0
    end

    test "a project deleted after it was loaded is not found", ctx do
      project = project_fixture(ctx.account)
      :ok = Projects.delete_project(ctx.account, project)

      assert WorkflowRuns.ingest(ctx.account, project, nil, minimal()) == {:error, :not_found}
      assert Repo.aggregate(Run, :count) == 0
    end

    test "the same run id under two projects stores two rows", ctx do
      second = project_fixture(ctx.account)

      {:ok, first} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())
      {:ok, other} = WorkflowRuns.ingest(ctx.account, second, nil, minimal())

      refute first.id == other.id
      refute other.duplicate
      assert count(account_id: ctx.account.id) == 2
    end

    test "the same run id stays isolated between accounts", ctx do
      other_project = project_fixture(ctx.other, %{"slug" => ctx.project.slug})
      changed = Map.put(minimal(), "duration_ms", 9)

      {:ok, mine} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())
      assert {:ok, theirs} = WorkflowRuns.ingest(ctx.other, other_project, nil, changed)

      refute theirs.duplicate
      refute theirs.id == mine.id
      assert Repo.get!(Run, theirs.id).duration_ms == 9
      assert Repo.get!(Run, mine.id).duration_ms == 0
    end
  end

  describe "idempotency" do
    test "an exact retry with reordered keys returns the same id", ctx do
      {:ok, first} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())

      assert {:ok, retry} =
               WorkflowRuns.ingest(ctx.account, ctx.project, nil, reorder_keys(minimal()))

      assert retry == %{first | duplicate: true}
      assert count(project_id: ctx.project.id) == 1
    end

    test "a retry of the first run is a duplicate after a second run is stored", ctx do
      {:ok, first} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())
      second = Map.put(minimal(), "run_id", @other_run_id)

      assert {:ok, %{duplicate: false}} =
               WorkflowRuns.ingest(ctx.account, ctx.project, nil, second)

      assert {:ok, %{id: id, duplicate: true}} =
               WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())

      assert id == first.id
      assert count(project_id: ctx.project.id) == 2
    end

    test "a reordered results array conflicts and leaves the row unchanged", ctx do
      {:ok, first} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, full())
      stored = Repo.get!(Run, first.id)
      swapped = Map.update!(full(), "results", &Enum.reverse/1)

      assert WorkflowRuns.ingest(ctx.account, ctx.project, nil, swapped) ==
               {:error, :workflow_run_conflict}

      assert Repo.get!(Run, first.id) == stored
      assert count(project_id: ctx.project.id) == 1
    end

    test "a conflicting outcome conflicts and leaves the row unchanged", ctx do
      {:ok, first} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())
      stored = Repo.get!(Run, first.id)

      assert WorkflowRuns.ingest(
               ctx.account,
               ctx.project,
               nil,
               Map.put(minimal(), "outcome", "cancelled")
             ) == {:error, :workflow_run_conflict}

      assert Repo.get!(Run, first.id) == stored
    end
  end

  describe "links" do
    @links %{
      "threads" => ["https://ampcode.com/threads/T-1", "https://ampcode.com/threads/a%7Eb"],
      "tickets" => ["GOO-291", "Goo-300"]
    }

    test "tickets are copied lowercased, threads as sent, and the document keeps both", ctx do
      document = Map.put(full(), "links", @links)
      assert {:ok, %{id: id}} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)

      run = Repo.get!(Run, id)
      assert run.link_tickets == ["goo-291", "goo-300"]
      assert run.link_threads == @links["threads"]
      assert run.payload == document
      assert run.payload["links"] == @links
    end

    test "a document without links stores as before, with empty link columns", ctx do
      assert {:ok, first} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())

      run = Repo.get!(Run, first.id)
      assert run.link_tickets == []
      assert run.link_threads == []
      assert run.payload == minimal()
      refute Map.has_key?(run.payload, "links")
      assert run.payload_digest == JsonDocument.digest(minimal())

      assert {:ok, retry} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())
      assert retry == %{first | duplicate: true}
    end

    test "an exact retry with reordered links keys is a duplicate", ctx do
      document = Map.put(minimal(), "links", @links)
      {:ok, first} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)

      reordered = reorder_keys(document)
      assert %Jason.OrderedObject{values: [{"tickets", _}, {"threads", _}]} = reordered["links"]

      assert {:ok, retry} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, reordered)
      assert retry == %{first | duplicate: true}
      assert count(project_id: ctx.project.id) == 1
    end

    test "a retry with a different ticket spelling conflicts and leaves the row unchanged",
         ctx do
      document = Map.put(minimal(), "links", %{"tickets" => ["GOO-291"]})
      {:ok, first} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)
      stored = Repo.get!(Run, first.id)

      respelled = put_in(document, ["links", "tickets"], ["goo-291"])

      assert WorkflowRuns.ingest(ctx.account, ctx.project, nil, respelled) ==
               {:error, :workflow_run_conflict}

      assert Repo.get!(Run, first.id) == stored
      assert stored.payload["links"]["tickets"] == ["GOO-291"]
    end
  end

  describe "storage failures" do
    test "a dropped connection is unavailable and stores nothing", ctx do
      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise DBConnection.ConnectionError, "tcp recv: closed"
      end)

      assert WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal()) ==
               {:error, :workflow_run_storage_unavailable}

      assert count(project_id: ctx.project.id) == 0
    end

    test "a foreign key other than the project's is unavailable", ctx do
      expect(Store, :insert_all, fn _schema, _rows, _opts ->
        raise postgres_error("23503", %{constraint: "workflow_runs_account_id_fkey"})
      end)

      assert WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal()) ==
               {:error, :workflow_run_storage_unavailable}
    end

    test "an API key deleted after authentication is unavailable", ctx do
      account_user = account_user_fixture(ctx.account, user_fixture(), :member)
      {api_key, _token} = api_key_fixture(account_user, %{type: :private})
      Repo.delete!(api_key)

      assert WorkflowRuns.ingest(ctx.account, ctx.project, api_key, minimal()) ==
               {:error, :workflow_run_storage_unavailable}

      assert count(project_id: ctx.project.id) == 0
    end

    test "transient SQLSTATEs are unavailable", ctx do
      for pg_code <- ~w(08000 08006 40001 40P01 53100 53300 57014 57P01 57P03 55P03 25006) do
        expect(Store, :insert_all, fn _schema, _rows, _opts -> raise postgres_error(pg_code) end)

        assert WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal()) ==
                 {:error, :workflow_run_storage_unavailable},
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
              WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())
            end

          assert Exception.message(error) == "workflow run storage failed (SQLSTATE 22P05)"
          refute inspect(error) =~ sentinel
        end)

      assert log =~ "SQLSTATE 22P05"
      refute log =~ sentinel
    end

    test "a lost commit is unavailable, and the exact retry is a duplicate", ctx do
      # The insert commits with its transaction; the reply to COMMIT is lost.
      expect(Store, :transaction, fn fun, opts ->
        _committed = call_original(Store, :transaction, [fun, opts])
        raise DBConnection.ConnectionError, "connection closed before the reply"
      end)

      assert WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal()) ==
               {:error, :workflow_run_storage_unavailable}

      [committed] = Repo.all(from r in Run, where: r.project_id == ^ctx.project.id, select: r.id)

      assert {:ok, %{id: ^committed, duplicate: true}} =
               WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())

      assert count(project_id: ctx.project.id) == 1
    end

    test "storage queries are not logged and use the configured timeout", ctx do
      timeout = WorkflowRuns.db_timeout_ms()
      assert timeout == 15_000

      expect(Store, :insert_all, fn schema, rows, opts ->
        assert opts[:log] == false
        assert opts[:timeout] == timeout
        call_original(Store, :insert_all, [schema, rows, opts])
      end)

      {:ok, _} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())

      expect(Store, :one, fn query, opts ->
        assert opts[:log] == false
        assert opts[:timeout] == timeout
        call_original(Store, :one, [query, opts])
      end)

      {:ok, _} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())
    end
  end
end
