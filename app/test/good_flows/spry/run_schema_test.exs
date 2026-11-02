defmodule GoodFlows.Spry.RunSchemaTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  test "a second active run for the same sprite violates the partial unique index" do
    account = account_fixture()
    recipe = recipe_fixture(project_fixture(account))
    run_fixture(account, recipe, sprite_name: "app-feat-x", status: "running")

    assert_raise Ecto.ConstraintError, ~r/runs_one_active_per_sprite_index/, fn ->
      run_fixture(account, recipe, sprite_name: "app-feat-x", status: "queued")
    end
  end

  test "finished runs and other sprites or accounts do not conflict" do
    account = account_fixture()
    recipe = recipe_fixture(project_fixture(account))
    run_fixture(account, recipe, sprite_name: "app-feat-x", status: "failed")
    run_fixture(account, recipe, sprite_name: "app-feat-x", status: "succeeded")
    run_fixture(account, recipe, sprite_name: "app-feat-x", status: "running")
    run_fixture(account, recipe, sprite_name: "app-feat-y", status: "running")

    other = account_fixture()

    run_fixture(other, recipe_fixture(project_fixture(other)),
      sprite_name: "app-feat-x",
      status: "running"
    )
  end
end
