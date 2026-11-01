defmodule GoodFlows.Spry.RecipesContextTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Spry

  setup do
    %{account: account_fixture(), other: account_fixture()}
  end

  test "list_recipes/1 returns only the account's recipes", %{account: account, other: other} do
    mine = recipe_fixture(account)
    _theirs = recipe_fixture(other)

    assert [%{id: id}] = Spry.list_recipes(account)
    assert id == mine.id
  end

  test "get_recipe/2 scopes by account", %{account: account, other: other} do
    recipe = recipe_fixture(account)

    assert {:ok, %{id: id}} = Spry.get_recipe(account, recipe.id)
    assert id == recipe.id
    assert Spry.get_recipe(other, recipe.id) == {:error, :not_found}
    assert Spry.get_recipe(account, "not-a-uuid") == {:error, :not_found}
    assert Spry.get_recipe(account, Ecto.UUID.generate()) == {:error, :not_found}
  end

  test "replace_recipe/3 replaces lists wholesale", %{account: account, other: other} do
    recipe = recipe_fixture(account)

    assert {:ok, updated} =
             Spry.replace_recipe(account, recipe.id, %{"name" => "new", "setup" => ["x"]})

    assert updated.name == "new"
    assert updated.setup == ["x"]
    assert updated.stop == []

    assert Spry.replace_recipe(other, recipe.id, %{"name" => "x"}) == {:error, :not_found}
  end

  test "replace_recipe/3 with a host step leaves the recipe unchanged", %{account: account} do
    recipe = recipe_fixture(account)

    assert {:error, %Ecto.Changeset{}} =
             Spry.replace_recipe(account, recipe.id, %{
               "name" => recipe.name,
               "teardown" => [%{"host" => "x"}]
             })

    assert {:ok, ^recipe} = Spry.get_recipe(account, recipe.id)
  end

  describe "delete_recipe/2" do
    test "deletes a recipe without active runs", %{account: account, other: other} do
      recipe = recipe_fixture(account)

      assert Spry.delete_recipe(other, recipe.id) == {:error, :not_found}
      assert Spry.delete_recipe(account, recipe.id) == :ok
      assert Spry.get_recipe(account, recipe.id) == {:error, :not_found}
    end

    test "refuses while a run is queued or running", %{account: account} do
      for status <- ["queued", "running"] do
        recipe = recipe_fixture(account)
        run_fixture(account, recipe, status: status)

        assert Spry.delete_recipe(account, recipe.id) == {:error, :active_run}
        assert {:ok, _} = Spry.get_recipe(account, recipe.id)
      end
    end

    test "keeps finished runs with the recipe detached", %{account: account} do
      recipe = recipe_fixture(account)
      run = run_fixture(account, recipe, status: "succeeded")

      assert Spry.delete_recipe(account, recipe.id) == :ok
      assert {:ok, fetched} = Spry.get_run(account, run.id)
      assert fetched.recipe_id == nil
    end
  end
end
