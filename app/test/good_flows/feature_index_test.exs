defmodule GoodFlows.FeatureIndexTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.FeatureIndex
  alias GoodFlows.FeatureIndex.Version
  alias GoodFlows.ReviewPolicies.Glob

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "FI #{System.unique_integer()}"})
    owner = Accounts.get_account_user(user, account)
    {key, _} = api_key_fixture(owner, %{type: :private})
    %{key: key, project: project_fixture(account)}
  end

  defp invalid(features) do
    assert {:error, {:invalid_body, errors}} = FeatureIndex.validate(%{"features" => features})
    errors
  end

  describe "validate" do
    test "accepts valid features" do
      assert {:ok, [_, _]} =
               FeatureIndex.validate(%{
                 "features" => [
                   feature("checkout", ["app/lib/shop/checkout/**"]),
                   feature("login", ["app/lib/good_flows_web/live/user_live/**"])
                 ]
               })
    end

    test "refuses empty, duplicate, bad ids, empty paths, bad globs, unknown keys" do
      assert %{"features" => _} = invalid([])
      assert %{"features" => _} = invalid([feature("login", ["a"]), feature("login", ["b"])])
      assert %{"features" => _} = invalid([feature("Login", ["a"])])
      assert %{"features" => _} = invalid([feature("login", [])])
      assert %{"features" => _} = invalid([feature("login", ["a/b**"])])
      assert %{"features" => _} = invalid([feature("login", [String.duplicate("a", 513)])])
      assert %{"features" => _} = invalid([Map.put(feature("login", ["a"]), "x", 1)])
      assert %{"features" => _} = invalid([%{feature("login", ["a"]) | "title" => ""}])
      assert %{"features" => _} = invalid(for i <- 1..501, do: feature("f#{i}", ["a"]))

      assert {:error, {:invalid_body, %{"body" => _}}} =
               FeatureIndex.validate(%{"features" => [feature("a", ["a"])], "extra" => 1})
    end
  end

  test "versions: create, duplicate, change; current and listing", ctx do
    assert {:error, :not_found} = FeatureIndex.current(ctx.project)
    body = %{"features" => [feature("checkout", ["app/lib/shop/checkout/**"])]}

    assert {:ok, :created, %Version{version: 1}} = FeatureIndex.sync(ctx.project, ctx.key, body)
    assert {:ok, :duplicate, %Version{version: 1}} = FeatureIndex.sync(ctx.project, ctx.key, body)

    changed = %{"features" => [feature("checkout", ["app/lib/shop/**"])]}

    assert {:ok, :created, %Version{version: 2}} =
             FeatureIndex.sync(ctx.project, ctx.key, changed)

    assert {:ok, %Version{version: 2}} = FeatureIndex.current(ctx.project)

    assert {:ok, %Version{version: 1, features: [%{"paths" => ["app/lib/shop/checkout/**"]}]}} =
             FeatureIndex.get_version(ctx.project, 1)

    {:ok, page} = FeatureIndex.list_versions(ctx.project, %{"limit" => "1"})
    assert [%Version{version: 2}] = page.versions
    {:ok, page} = FeatureIndex.list_versions(ctx.project, %{"cursor" => page.next_cursor})
    assert [%Version{version: 1}] = page.versions
    assert %{version: 2} = FeatureIndex.compiled(ctx.project.id)
  end

  describe "map_files" do
    defp features(list),
      do: Enum.map(list, fn {id, globs} -> {id, Enum.map(globs, &Glob.compile/1)} end)

    test "nested file, multi-feature, unmapped, ignored and renamed" do
      index =
        features([
          {"checkout", ["app/lib/shop/checkout/**", "app/lib/shared/**"]},
          {"billing", ["app/lib/shared/money.ex"]}
        ])

      files = [
        file("app/lib/shop/checkout/steps/pay.ex"),
        file("app/lib/shop/cart.ex"),
        file("app/lib/shared/money.ex"),
        file("docs/usage.md"),
        file("app/lib/misc/new.ex", %{
          "status" => "renamed",
          "old_path" => "app/lib/shop/checkout/old.ex"
        })
      ]

      mapping = FeatureIndex.map_files(files, index, [Glob.compile("docs/**")])
      assert mapping.features == ["billing", "checkout"]
      assert mapping.unmapped == ["app/lib/shop/cart.ex"]

      assert %{unmapped: ["app/lib/shop/cart.ex", "docs/usage.md"]} =
               FeatureIndex.map_files(files, index, [])
    end

    test "a rename into an ignored path is mapped through its old_path" do
      index = features([{"checkout", ["app/lib/shop/checkout/**"]}])
      ignore = [Glob.compile("docs/**")]

      moved =
        file("docs/x.md", %{"status" => "renamed", "old_path" => "app/lib/shop/checkout/x.ex"})

      assert %{features: ["checkout"], unmapped: []} =
               FeatureIndex.map_files([moved], index, ignore)

      unmapped_move = file("docs/x.md", %{"status" => "renamed", "old_path" => "app/x.ex"})

      assert %{features: [], unmapped: ["docs/x.md"]} =
               FeatureIndex.map_files([unmapped_move], index, ignore)

      refute FeatureIndex.ignored?(unmapped_move, ignore)

      assert FeatureIndex.ignored?(
               file("docs/b.md", %{"status" => "renamed", "old_path" => "docs/a.md"}),
               ignore
             )
    end
  end
end
