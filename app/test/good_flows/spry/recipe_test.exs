defmodule GoodFlows.Spry.RecipeTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures

  alias GoodFlows.Spry
  alias GoodFlows.Spry.Recipe

  defp changeset(attrs), do: Recipe.changeset(%Recipe{}, attrs)

  describe "schema" do
    test "accepts all four phases in order" do
      cs =
        changeset(%{
          "name" => "myapp-{{branch_slug}}",
          "setup" => ["a", "b"],
          "start" => ["c"],
          "stop" => ["d"],
          "teardown" => ["e", "f"]
        })

      assert cs.valid?
      assert get_field(cs, :setup) == ["a", "b"]
      assert get_field(cs, :teardown) == ["e", "f"]
    end

    test "defaults omitted phases to empty lists" do
      cs = changeset(%{"name" => "demo"})
      assert cs.valid?

      for phase <- Recipe.phases() do
        assert get_field(cs, phase) == []
      end
    end

    test "requires a non-blank name" do
      assert %{name: ["can't be blank"]} = errors_on(changeset(%{}))
      assert %{name: ["can't be blank"]} = errors_on(changeset(%{"name" => "   "}))
    end

    test "rejects blank step strings with the phase and index" do
      errors = errors_on(changeset(%{"name" => "x", "setup" => ["ok", "  "], "stop" => [""]}))
      assert errors["setup[1]"] == ["can't be blank"]
      assert errors["stop[0]"] == ["can't be blank"]
    end

    test "replacing an existing recipe still requires name" do
      existing = %Recipe{name: "old", setup: ["a"]}
      cs = Recipe.changeset(existing, %{"setup" => ["b"]})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "indexed error keys are strings, never new atoms" do
      cs = changeset(%{"name" => "x", "setup" => List.duplicate("ok", 437) ++ [""]})
      assert {"setup[437]", {"can't be blank", _}} = List.keyfind(cs.errors, "setup[437]", 0)
      assert_raise ArgumentError, fn -> String.to_existing_atom("setup[437]") end
    end

    test "rejects a phase with more than 500 items" do
      assert %{setup: ["must have at most 500 items"]} =
               errors_on(changeset(%{"name" => "x", "setup" => List.duplicate("ok", 501)}))

      assert changeset(%{"name" => "x", "setup" => List.duplicate("ok", 500)}).valid?
    end

    test "rejects a phase that is not a list" do
      assert %{start: ["must be a list of strings"]} =
               errors_on(changeset(%{"name" => "x", "start" => "echo hi"}))
    end
  end

  describe "host steps" do
    test "rejects a host map with the phase and index" do
      errors =
        errors_on(
          changeset(%{
            "name" => "x",
            "setup" => ["echo", %{"host" => "gh repo deploy-key add ..."}]
          })
        )

      assert errors["setup[1]"] == ["host steps are not supported by the API"]
    end

    test "rejects numbers, nulls, and nested lists" do
      errors = errors_on(changeset(%{"name" => "x", "teardown" => [1, nil, ["echo"]]}))

      for index <- 0..2 do
        assert errors["teardown[#{index}]"] == ["host steps are not supported by the API"]
      end
    end
  end

  test "rejects org" do
    assert %{org: [message]} = errors_on(changeset(%{"name" => "x", "org" => "acme"}))
    assert message =~ "not supported"
  end

  describe "placeholders" do
    test "rejects unknown placeholders in a step, naming it and the phase" do
      errors = errors_on(changeset(%{"name" => "x", "start" => ["echo {{foo}}"]}))
      assert [message] = errors["start[0]"]
      assert message =~ "{{foo}}"
      assert message =~ "start"
    end

    test "rejects {{sprite}} in the name" do
      assert %{name: [message]} = errors_on(changeset(%{"name" => "app-{{sprite}}"}))
      assert message =~ "{{sprite}}"
    end

    test "rejects unknown placeholders in the name" do
      assert %{name: [message]} = errors_on(changeset(%{"name" => "app-{{org}}"}))
      assert message =~ "{{org}}"
    end

    test "accepts {{sprite}} in steps and known placeholders in the name" do
      assert changeset(%{
               "name" => "app-{{branch_slug}}-{{commit}}",
               "setup" => ["echo {{sprite}} {{remote}} {{branch}}"]
             }).valid?
    end
  end

  describe "uniqueness" do
    test "names are unique per account" do
      account = account_fixture()
      assert {:ok, _} = Spry.create_recipe(account, %{"name" => "myapp-{{branch_slug}}"})

      assert {:error, cs} = Spry.create_recipe(account, %{"name" => "myapp-{{branch_slug}}"})
      assert %{name: [_]} = errors_on(cs)
    end

    test "the same name is allowed in another account" do
      assert {:ok, _} = Spry.create_recipe(account_fixture(), %{"name" => "demo"})
      assert {:ok, _} = Spry.create_recipe(account_fixture(), %{"name" => "demo"})
    end
  end

  describe "sprite name templates" do
    test "accepts lowercase literal names and templates with valid literal parts" do
      for name <- [
            "box",
            "app-1",
            "0x",
            "app-{{branch_slug}}",
            "{{commit}}",
            "{{branch_slug}}-db"
          ] do
        assert changeset(%{"name" => name}).valid?, "rejected #{name}"
      end
    end

    test "rejects literal names that can never be valid sprite names" do
      for name <- [
            "App",
            "app#1",
            "app?x",
            "a..b",
            "a.b",
            "a_b",
            "-app",
            "app name",
            "Box-{{branch_slug}}",
            "-{{branch_slug}}",
            String.duplicate("a", 64),
            String.duplicate("a", 62) <> "{{commit}}{{remote}}"
          ] do
        cs = changeset(%{"name" => name})
        refute cs.valid?, "accepted #{inspect(name)}"
        assert [message] = errors_on(cs).name
        assert message =~ "valid sprite name"
      end
    end

    test "names that differ only by case cannot both exist" do
      assert changeset(%{"name" => "box"}).valid?
      refute changeset(%{"name" => "BOX"}).valid?
    end
  end

  describe "lengths" do
    test "an oversized name is a validation error" do
      cs = changeset(%{"name" => String.duplicate("{{commit}}", 30)})
      assert "should be at most 255 character(s)" in errors_on(cs).name
    end

    test "an oversized line is a validation error keyed by phase and index" do
      cs = changeset(%{"name" => "box", "setup" => ["ok", String.duplicate("x", 10_001)]})
      refute cs.valid?

      assert {"setup[1]", {"should be at most %{count} character(s)", opts}} =
               Enum.find(cs.errors, &(elem(&1, 0) == "setup[1]"))

      assert opts[:count] == 10_000
      assert changeset(%{"name" => "box", "setup" => [String.duplicate("x", 10_000)]}).valid?
    end
  end
end
