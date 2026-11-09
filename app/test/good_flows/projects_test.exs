defmodule GoodFlows.ProjectsTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Projects
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.Spry.{Recipe, Run}
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
