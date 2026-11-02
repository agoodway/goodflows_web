defmodule GoodFlows.Spry.RecipesContextTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Projects
  alias GoodFlows.Spry

  setup do
    account = account_fixture()
    other = account_fixture()

    %{
      account: account,
      project: project_fixture(account),
      sibling: project_fixture(account, %{"slug" => "other"}),
      other: other,
      other_project: project_fixture(other)
    }
  end

  test "list_recipes/2 returns only the project's recipes", ctx do
    mine = recipe_fixture(ctx.project)
    _sibling = recipe_fixture(ctx.sibling)
    _theirs = recipe_fixture(ctx.other_project)

    assert [%{id: id} = listed] = Spry.list_recipes(ctx.account, ctx.project)
    assert id == mine.id
    assert listed.project == ctx.project
    assert Spry.list_recipes(ctx.other, ctx.project) == []
  end

  test "create_recipe/3 sets the owners from the project", ctx do
    assert {:ok, recipe} = Spry.create_recipe(ctx.account, ctx.project, %{"name" => "demo"})
    assert recipe.project_id == ctx.project.id
    assert recipe.account_id == ctx.account.id
    assert recipe.project == ctx.project

    assert Spry.create_recipe(ctx.other, ctx.project, %{"name" => "x"}) == {:error, :not_found}
  end

  test "create_recipe/3 rejects a body project and ignores a body project_id", ctx do
    assert {:error, cs} =
             Spry.create_recipe(ctx.account, ctx.project, %{
               "name" => "demo",
               "project" => "other"
             })

    assert %{project: [_]} = errors_on(cs)

    assert {:ok, recipe} =
             Spry.create_recipe(ctx.account, ctx.project, %{
               "name" => "demo",
               "project_id" => ctx.sibling.id
             })

    assert recipe.project_id == ctx.project.id
  end

  test "create_recipe/3 under a deleted project is :not_found", ctx do
    {:ok, gone} = Projects.create_project(ctx.account, %{"slug" => "gone"})
    :ok = Projects.delete_project(ctx.account, gone)

    assert Spry.create_recipe(ctx.account, gone, %{"name" => "demo"}) == {:error, :not_found}
  end

  test "names are unique per project, not per account", ctx do
    recipe_fixture(ctx.project, %{"name" => "demo"})

    assert {:error, cs} = Spry.create_recipe(ctx.account, ctx.project, %{"name" => "demo"})
    assert %{name: [_]} = errors_on(cs)

    assert {:ok, _} = Spry.create_recipe(ctx.account, ctx.sibling, %{"name" => "demo"})
  end

  test "get_recipe/3 scopes by account and project", ctx do
    recipe = recipe_fixture(ctx.project)

    assert {:ok, %{id: id} = fetched} = Spry.get_recipe(ctx.account, ctx.project, recipe.id)
    assert id == recipe.id
    assert fetched.project == ctx.project
    assert Spry.get_recipe(ctx.account, ctx.sibling, recipe.id) == {:error, :not_found}
    assert Spry.get_recipe(ctx.other, ctx.project, recipe.id) == {:error, :not_found}
    assert Spry.get_recipe(ctx.other, ctx.other_project, recipe.id) == {:error, :not_found}
    assert Spry.get_recipe(ctx.account, ctx.project, "not-a-uuid") == {:error, :not_found}

    assert Spry.get_recipe(ctx.account, ctx.project, Ecto.UUID.generate()) ==
             {:error, :not_found}
  end

  test "replace_recipe/4 replaces lists wholesale and keeps the project", ctx do
    recipe = recipe_fixture(ctx.project)

    assert {:ok, updated} =
             Spry.replace_recipe(ctx.account, ctx.project, recipe.id, %{
               "name" => "new",
               "setup" => ["x"],
               "project_id" => ctx.sibling.id
             })

    assert updated.name == "new"
    assert updated.setup == ["x"]
    assert updated.stop == []
    assert updated.project_id == ctx.project.id
    assert updated.project == ctx.project

    assert {:ok, %{project_id: project_id}} =
             Spry.get_recipe(ctx.account, ctx.project, recipe.id)

    assert project_id == ctx.project.id

    assert Spry.replace_recipe(ctx.other, ctx.project, recipe.id, %{"name" => "x"}) ==
             {:error, :not_found}

    assert Spry.replace_recipe(ctx.account, ctx.sibling, recipe.id, %{"name" => "x"}) ==
             {:error, :not_found}
  end

  test "replace_recipe/4 with a body project is rejected and changes nothing", ctx do
    recipe = recipe_fixture(ctx.project)

    assert {:error, cs} =
             Spry.replace_recipe(ctx.account, ctx.project, recipe.id, %{
               "name" => "new",
               "project" => "other"
             })

    assert %{project: [_]} = errors_on(cs)
    assert {:ok, ^recipe} = Spry.get_recipe(ctx.account, ctx.project, recipe.id)
  end

  test "replace_recipe/4 with a host step leaves the recipe unchanged", ctx do
    recipe = recipe_fixture(ctx.project)

    assert {:error, %Ecto.Changeset{}} =
             Spry.replace_recipe(ctx.account, ctx.project, recipe.id, %{
               "name" => recipe.name,
               "teardown" => [%{"host" => "x"}]
             })

    assert {:ok, ^recipe} = Spry.get_recipe(ctx.account, ctx.project, recipe.id)
  end

  describe "delete_recipe/3" do
    test "deletes a recipe without active runs", ctx do
      recipe = recipe_fixture(ctx.project)

      assert Spry.delete_recipe(ctx.other, ctx.project, recipe.id) == {:error, :not_found}
      assert Spry.delete_recipe(ctx.account, ctx.project, recipe.id) == :ok
      assert Spry.get_recipe(ctx.account, ctx.project, recipe.id) == {:error, :not_found}
    end

    test "a wrong-project delete is :not_found and keeps the recipe", ctx do
      recipe = recipe_fixture(ctx.project)

      assert Spry.delete_recipe(ctx.account, ctx.sibling, recipe.id) == {:error, :not_found}
      assert {:ok, _} = Spry.get_recipe(ctx.account, ctx.project, recipe.id)
    end

    test "refuses while a run is queued or running", ctx do
      for status <- ["queued", "running"] do
        recipe = recipe_fixture(ctx.project)
        run_fixture(ctx.account, recipe, status: status)

        assert Spry.delete_recipe(ctx.account, ctx.project, recipe.id) == {:error, :active_run}
        assert {:ok, _} = Spry.get_recipe(ctx.account, ctx.project, recipe.id)
      end
    end

    test "keeps finished runs with the recipe detached", ctx do
      recipe = recipe_fixture(ctx.project)
      run = run_fixture(ctx.account, recipe, status: "succeeded")

      assert Spry.delete_recipe(ctx.account, ctx.project, recipe.id) == :ok
      assert {:ok, fetched} = Spry.get_run(ctx.account, run.id)
      assert fetched.recipe_id == nil
      assert fetched.recipe == nil
    end
  end

  describe "Projects.delete_project/2" do
    test "refuses while a recipe remains, including one with finished runs", ctx do
      recipe = recipe_fixture(ctx.project)
      run_fixture(ctx.account, recipe, status: "succeeded")

      assert Projects.delete_project(ctx.account, ctx.project) == {:error, :has_recipes}
      assert {:ok, _} = Projects.get_project(ctx.account, ctx.project.slug)
      assert {:ok, _} = Spry.get_recipe(ctx.account, ctx.project, recipe.id)
    end

    test "succeeds once the recipes are gone", ctx do
      recipe = recipe_fixture(ctx.project)
      :ok = Spry.delete_recipe(ctx.account, ctx.project, recipe.id)

      assert Projects.delete_project(ctx.account, ctx.project) == :ok
    end
  end
end
