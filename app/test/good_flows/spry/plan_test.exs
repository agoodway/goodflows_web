defmodule GoodFlows.Spry.PlanTest do
  use GoodFlows.DataCase, async: true

  alias GoodFlows.Spry.{Plan, Recipe}

  @recipe %Recipe{
    name: "app-{{branch_slug}}",
    setup: ["git clone {{remote}} app", "cd app && git checkout {{commit}}"],
    start: ["echo start {{sprite}}"],
    stop: [],
    teardown: ["echo bye"]
  }

  defp build(params, recipe \\ @recipe), do: Plan.build(recipe, params)

  defp plan!(params, recipe \\ @recipe) do
    {:ok, plan} = build(params, recipe)
    plan
  end

  describe "build/2" do
    test "resolves the name and expands the phase lines" do
      plan =
        plan!(%{
          "phase" => "setup",
          "branch" => "feat/x",
          "commit" => "abc",
          "remote" => "git@example.com:a/b.git"
        })

      assert plan.sprite_name == "app-feat-x"

      assert plan.commands == [
               "git clone git@example.com:a/b.git app",
               "cd app && git checkout abc"
             ]

      assert plan.inputs["branch"] == "feat/x"
    end

    test "the sprite override replaces the recipe name and fills {{sprite}}" do
      plan = plan!(%{"phase" => "start", "sprite" => "demo"})
      assert plan.sprite_name == "demo"
      assert plan.commands == ["echo start demo"]
    end

    test "rejects an invalid or missing phase" do
      assert {:error, cs} = build(%{"phase" => "deploy"})
      assert %{phase: [_]} = errors_on(cs)
      assert {:error, cs} = build(%{})
      assert %{phase: ["can't be blank"]} = errors_on(cs)
    end

    test "flags are phase-specific" do
      assert {:error, cs} = build(%{"phase" => "setup", "no_destroy" => true, "branch" => "x"})
      assert %{no_destroy: [_]} = errors_on(cs)

      assert {:error, cs} = build(%{"phase" => "teardown", "no_create" => true, "branch" => "x"})
      assert %{no_create: [_]} = errors_on(cs)

      assert {:ok, %{no_create: true}} =
               build(%{
                 "phase" => "setup",
                 "no_create" => true,
                 "sprite" => "s",
                 "commit" => "c",
                 "remote" => "r"
               })

      assert {:ok, %{no_destroy: true}} =
               build(%{"phase" => "teardown", "no_destroy" => true, "branch" => "x"})
    end

    test "a name needing branch names branch_slug and the branch field" do
      assert {:error, cs} = build(%{"phase" => "teardown"})
      assert %{branch: [message]} = errors_on(cs)
      assert message =~ "{{branch_slug}}"
    end

    test "a later step needing remote fails the whole request" do
      assert {:error, cs} = build(%{"phase" => "setup", "branch" => "x", "commit" => "c"})
      assert %{remote: [message]} = errors_on(cs)
      assert message =~ "{{remote}}"
      assert message =~ "setup[0]"
    end

    test "no placeholders needs no inputs" do
      recipe = %Recipe{name: "demo", setup: ["echo hi"], start: [], stop: [], teardown: []}

      assert {:ok, %{sprite_name: "demo", commands: ["echo hi"]}} =
               build(%{"phase" => "setup"}, recipe)
    end

    test "an expanded name with a slash suggests {{branch_slug}}" do
      recipe = %Recipe{name: "{{branch}}", setup: [], start: [], stop: [], teardown: []}

      assert {:error, cs} =
               build(%{"phase" => "setup", "branch" => "feature/add-dashboard"}, recipe)

      assert %{sprite_name: [message]} = errors_on(cs)
      assert message =~ "{{branch_slug}}"
    end

    test "an override with an unknown placeholder is rejected" do
      assert {:error, cs} = build(%{"phase" => "start", "sprite" => "x-{{sprite}}"})
      assert %{sprite: [_]} = errors_on(cs)
    end

    test "an empty branch slug counts as missing" do
      assert {:error, cs} = build(%{"phase" => "teardown", "branch" => "///"})
      assert %{branch: [_]} = errors_on(cs)
    end
  end

  describe "with_vm_state/2" do
    defp plan_for(phase, opts \\ []) do
      %Plan{
        phase: phase,
        sprite_name: "s1",
        commands: ["a", "b"],
        no_create: Keyword.get(opts, :no_create, false),
        no_destroy: Keyword.get(opts, :no_destroy, false)
      }
    end

    defp kinds({:ok, actions}), do: Enum.map(actions, & &1.kind)

    test "setup" do
      assert kinds(Plan.with_vm_state(plan_for("setup"), true)) == ["exec", "exec"]
      assert kinds(Plan.with_vm_state(plan_for("setup"), false)) == ["create", "exec", "exec"]

      assert kinds(Plan.with_vm_state(plan_for("setup", no_create: true), true)) == [
               "exec",
               "exec"
             ]

      assert {:error, message} = Plan.with_vm_state(plan_for("setup", no_create: true), false)
      assert message =~ "does not exist"
    end

    test "empty setup still creates a missing VM" do
      plan = %{plan_for("setup") | commands: []}
      assert {:ok, [%{kind: "create", command: "create s1"}]} = Plan.with_vm_state(plan, false)
    end

    test "start and stop require the VM" do
      for phase <- ["start", "stop"] do
        assert kinds(Plan.with_vm_state(plan_for(phase), true)) == ["exec", "exec"]
        assert {:error, message} = Plan.with_vm_state(plan_for(phase), false)
        assert message =~ "does not exist"
      end
    end

    test "teardown destroys unless no_destroy" do
      assert kinds(Plan.with_vm_state(plan_for("teardown"), true)) == ["exec", "exec", "destroy"]

      assert kinds(Plan.with_vm_state(plan_for("teardown", no_destroy: true), true)) ==
               ["exec", "exec"]

      for opts <- [[], [no_destroy: true]] do
        assert {:error, _} = Plan.with_vm_state(plan_for("teardown", opts), false)
      end
    end

    test "empty teardown still destroys" do
      plan = %{plan_for("teardown") | commands: []}
      assert {:ok, [%{kind: "destroy"}]} = Plan.with_vm_state(plan, true)
    end
  end

  describe "input validation" do
    @plain %Recipe{name: "box", setup: ["echo {{branch}} {{commit}} {{remote}}"]}

    test "accepts typical branches, commits, and remotes" do
      assert {:ok, _} =
               build(
                 %{
                   "phase" => "setup",
                   "branch" => "feature/add-dashboard_v2.1+x",
                   "commit" => "abc123def",
                   "remote" => "git@github.com:example-org/example-app.git"
                 },
                 @plain
               )

      assert {:ok, _} =
               build(%{"phase" => "setup", "remote" => "https://github.com/o/r.git"}, %Recipe{
                 name: "box",
                 setup: ["echo {{remote}}"]
               })
    end

    test "rejects shell metacharacters, option-like values, and oversized inputs" do
      for {field, value} <- [
            {"branch", "x;id"},
            {"branch", "$(id)"},
            {"branch", "a b"},
            {"branch", "-x"},
            {"branch", "a`id`"},
            {"commit", "abc|id"},
            {"commit", "--help"},
            {"remote", "https://x/?a=1&b=2"},
            {"remote", "'quoted'"},
            {"branch", String.duplicate("a", 256)},
            {"commit", String.duplicate("a", 256)},
            {"remote", String.duplicate("a", 1025)}
          ] do
        assert {:error, cs} = build(%{"phase" => "setup", field => value}, @plain)
        assert Map.has_key?(errors_on(cs), String.to_existing_atom(field)), "#{field}: #{value}"
      end
    end
  end

  describe "sprite names" do
    test "an expanded name must be lowercase letters, digits, and hyphens" do
      for branch <- ["Feat-X", "feat.x", "feat_x"] do
        assert {:error, cs} =
                 build(%{
                   "phase" => "setup",
                   "branch" => branch,
                   "remote" => "r",
                   "commit" => "c"
                 })

        assert [message] = errors_on(cs).sprite_name
        assert message =~ "not a valid sprite name"
      end

      assert {:ok, %{sprite_name: "app-feat-x"}} =
               build(%{
                 "phase" => "setup",
                 "branch" => "feat/x",
                 "remote" => "r",
                 "commit" => "c"
               })
    end

    test "an expanded name longer than 63 characters is rejected" do
      branch = String.duplicate("a", 60)
      assert {:error, cs} = build(%{"phase" => "start", "branch" => branch})
      assert errors_on(cs).sprite_name
    end

    test "the sprite override must form a valid name" do
      for sprite <- ["Demo", "demo#1", "demo?x", "a..b", "-demo", String.duplicate("a", 256)] do
        assert {:error, cs} = build(%{"phase" => "start", "sprite" => sprite}), sprite
        assert errors_on(cs)[:sprite] || errors_on(cs)[:sprite_name]
      end

      assert {:ok, %{sprite_name: "demo-2"}} = build(%{"phase" => "start", "sprite" => "demo-2"})
    end
  end
end
