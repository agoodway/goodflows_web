defmodule GoodFlows.ProjectsTest do
  use GoodFlows.DataCase, async: true

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures
  import GoodFlows.WorkflowRunFixtures

  alias GoodFlows.Accounts.Account
  alias GoodFlows.ChangeRequests
  alias GoodFlows.FeatureIndex
  alias GoodFlows.FeatureIndex.Version, as: FeatureIndexVersion
  alias GoodFlows.Projects
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.ScenarioSets
  alias GoodFlows.Spry.{Recipe, Run}
  alias GoodFlows.TestReports.Report
  alias GoodFlows.VerifyRuns
  alias GoodFlows.VerifyRuns.Artifact
  alias GoodFlows.VerifyRuns.Run, as: VerifyRun
  alias GoodFlows.VerifyRuns.Sweep
  alias GoodFlows.WorkflowRuns.Run, as: WorkflowRun

  setup do
    %{account: account_fixture(), other: account_fixture()}
  end

  describe "create_project/2" do
    test "creates a project for the account", %{account: account} do
      assert {:ok, %Project{} = project} =
               Projects.create_project(account, %{"slug" => "goodcases"})

      assert project.slug == "goodcases"
      assert project.account_id == account.id
    end

    test "a duplicate slug in the account is an error on slug", %{account: account} do
      {:ok, _} = Projects.create_project(account, %{"slug" => "goodcases"})

      assert {:error, changeset} = Projects.create_project(account, %{"slug" => "goodcases"})
      assert %{slug: [_]} = errors_on(changeset)
      assert [_] = Projects.list_projects(account)
    end

    test "another account may use the same slug", %{account: account, other: other} do
      {:ok, _} = Projects.create_project(account, %{"slug" => "goodcases"})
      assert {:ok, _} = Projects.create_project(other, %{"slug" => "goodcases"})
    end

    test "rejects invalid slugs", %{account: account} do
      for slug <- [
            "GoodCases",
            "-app",
            "_app",
            "abc\n",
            "",
            "a b",
            "é",
            String.duplicate("a", 65)
          ] do
        assert {:error, changeset} = Projects.create_project(account, %{"slug" => slug}),
               "expected #{inspect(slug)} to be rejected"

        assert %{slug: _} = errors_on(changeset)
      end

      assert {:error, _} = Projects.create_project(account, %{})
      assert Projects.list_projects(account) == []
    end

    test "accepts a 64-byte slug", %{account: account} do
      assert {:ok, _} = Projects.create_project(account, %{"slug" => String.duplicate("a", 64)})
    end
  end

  test "valid_slug?/1 shares the slug rule" do
    assert Project.valid_slug?("goodcases")
    assert Project.valid_slug?("0app_x-y")
    assert Project.valid_slug?(String.duplicate("a", 64))
    refute Project.valid_slug?("abc\n")
    refute Project.valid_slug?("GoodCases")
    refute Project.valid_slug?("")
    refute Project.valid_slug?(String.duplicate("a", 65))
    refute Project.valid_slug?(nil)
  end

  test "list_projects/1 is limited to the account and ordered by slug", ctx do
    for slug <- ["zeta", "alpha", "mid"],
        do: Projects.create_project(ctx.account, %{"slug" => slug})

    {:ok, _} = Projects.create_project(ctx.other, %{"slug" => "beta"})

    assert ctx.account |> Projects.list_projects() |> Enum.map(& &1.slug) == [
             "alpha",
             "mid",
             "zeta"
           ]
  end

  test "get_project/2 scopes by account", %{account: account, other: other} do
    {:ok, project} = Projects.create_project(account, %{"slug" => "goodcases"})

    assert {:ok, %Project{id: id}} = Projects.get_project(account, "goodcases")
    assert id == project.id
    assert Projects.get_project(other, "goodcases") == {:error, :not_found}
    assert Projects.get_project(account, "missing") == {:error, :not_found}
  end

  test "delete_project/2 deletes an empty project", %{account: account, other: other} do
    {:ok, project} = Projects.create_project(account, %{"slug" => "goodcases"})

    assert Projects.delete_project(other, project) == {:error, :not_found}
    assert Projects.delete_project(account, project) == :ok
    assert Projects.get_project(account, "goodcases") == {:error, :not_found}
  end

  test "delete_project/2 refuses a project whose only content is a workflow run", ctx do
    project = project_fixture(ctx.account)
    id = stored_run(ctx.account, project)

    assert Projects.delete_project(ctx.account, project) == {:error, :has_workflow_runs}
    assert {:ok, _} = Projects.get_project(ctx.account, project.slug)
    assert Repo.get(WorkflowRun, id)
  end

  test "delete_project/2 refuses a project whose only content is a closed change request", ctx do
    project = project_fixture(ctx.account)
    user = GoodFlows.AccountsFixtures.user_fixture()
    au = GoodFlows.AccountsFixtures.account_user_fixture(ctx.account, user, :member)
    {key, _token} = GoodFlows.AccountsFixtures.api_key_fixture(au, %{type: :private})

    {:ok, cr} =
      GoodFlows.ChangeRequests.create(ctx.account, project, key, %{
        "title" => "t",
        "source_branch" => "b"
      })

    {:ok, _closed} = GoodFlows.ChangeRequests.transition(cr, key, :close)

    assert Projects.delete_project(ctx.account, project) == {:error, :has_change_requests}
    assert {:ok, _} = Projects.get_project(ctx.account, project.slug)
    assert Repo.get(GoodFlows.ChangeRequests.ChangeRequest, cr.id)
  end

  test "delete_project/2 reports test reports when the project also has a workflow run", ctx do
    project = project_fixture(ctx.account)
    %{id: report_id} = stored_report_fixture(ctx.account, project)
    run_id = stored_run(ctx.account, project)

    assert Projects.delete_project(ctx.account, project) == {:error, :has_test_reports}
    assert {:ok, _} = Projects.get_project(ctx.account, project.slug)
    assert Repo.get(Report, report_id)
    assert Repo.get(WorkflowRun, run_id)
  end

  describe "delete_project/2 with grading content" do
    setup ctx do
      user = GoodFlows.AccountsFixtures.user_fixture()
      au = GoodFlows.AccountsFixtures.account_user_fixture(ctx.account, user, :member)
      {key, _token} = GoodFlows.AccountsFixtures.api_key_fixture(au, %{type: :private})
      %{key: key, project: project_fixture(ctx.account)}
    end

    # A verify run whose change request (and scenario set) were removed, so
    # the run is the project's only content. Options go to `run_doc/5`.
    defp only_verify_run(ctx, opts) do
      {:ok, cr} =
        ChangeRequests.create(ctx.account, ctx.project, ctx.key, %{
          "title" => "t",
          "source_branch" => "b",
          "openspec_change" => "add-x"
        })

      fm = intent_fm("add-x", [scenario("S1")])
      {:ok, :created, set} = ScenarioSets.upload(cr, ctx.key, set_body(fm))
      doc = run_doc(set.digest, "intent", String.duplicate("1", 40), [result("S1")], opts)
      {:ok, ingested} = VerifyRuns.ingest(ctx.account, ctx.project, ctx.key, doc)
      Repo.delete!(cr)
      ingested
    end

    test "a final verify run is :has_verify_runs, also with expired artifacts", ctx do
      %{run: run} = only_verify_run(ctx, [])
      assert Projects.delete_project(ctx.account, ctx.project) == {:error, :has_verify_runs}

      Repo.insert!(%Artifact{
        verify_run_id: run.id,
        artifact_id: "a",
        object_key: "verify-runs/#{run.id}/a",
        size: 1,
        sha256: String.duplicate("0", 64),
        content_type: "image/png",
        expired: true
      })

      assert Projects.delete_project(ctx.account, ctx.project) == {:error, :has_verify_runs}
      assert Repo.get(VerifyRun, run.id)
      assert {:ok, _} = Projects.get_project(ctx.account, ctx.project.slug)
    end

    test "an uploading run blocks until the sweep deletes it", ctx do
      %{run: run} = only_verify_run(ctx, artifacts: [artifact("a", "bytes")])
      assert run.status == "uploading"
      assert Projects.delete_project(ctx.account, ctx.project) == {:error, :has_verify_runs}

      Repo.update_all(from(r in VerifyRun, where: r.id == ^run.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      Sweep.run()
      assert Projects.delete_project(ctx.account, ctx.project) == :ok
    end

    test "a feature index is deleted with the project", ctx do
      {:ok, :created, _} =
        FeatureIndex.sync(ctx.project, ctx.key, %{"features" => [feature("x", ["lib/**"])]})

      assert Projects.delete_project(ctx.account, ctx.project) == :ok
      assert Projects.get_project(ctx.account, ctx.project.slug) == {:error, :not_found}
      refute Repo.exists?(from v in FeatureIndexVersion, where: v.project_id == ^ctx.project.id)
    end
  end

  test "delete_project/2 of an already-deleted project is :not_found", %{account: account} do
    project = project_fixture(account)
    Repo.delete!(project)

    assert Projects.delete_project(account, project) == {:error, :not_found}
  end

  test "deleting an account removes its projects, recipes, and runs", ctx do
    project = project_fixture(ctx.account)
    recipe = recipe_fixture(project)
    run = run_fixture(ctx.account, recipe, status: "succeeded")

    other_project = project_fixture(ctx.other)
    other_recipe = recipe_fixture(other_project)

    Repo.delete!(ctx.account)

    refute Repo.get(Account, ctx.account.id)
    refute Repo.get(Project, project.id)
    refute Repo.get(Recipe, recipe.id)
    refute Repo.get(Run, run.id)

    assert Repo.get(Project, other_project.id)
    assert Repo.get(Recipe, other_recipe.id)
  end

  describe "recipes foreign key" do
    test "a recipe's account must match its project's account", ctx do
      project = project_fixture(ctx.other)

      assert_raise Ecto.ConstraintError, ~r/recipes_project_id_fkey/, fn ->
        Repo.insert!(%Recipe{account_id: ctx.account.id, project_id: project.id, name: "x"})
      end
    end

    test "a project with recipes cannot be deleted directly", %{account: account} do
      project = project_fixture(account)
      recipe_fixture(project)

      assert_raise Postgrex.Error, ~r/recipes_project_id_fkey/, fn ->
        Repo.query!("DELETE FROM projects WHERE id = $1", [Ecto.UUID.dump!(project.id)])
      end
    end
  end
end
