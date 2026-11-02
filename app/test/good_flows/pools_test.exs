defmodule GoodFlows.PoolsTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Pools
  alias GoodFlows.Pools.{Config, Member}
  alias GoodFlows.Projects

  setup do
    account = account_fixture()
    credential_fixture(account)
    %{account: account, project: project_fixture(account, %{"slug" => "app"})}
  end

  defp create(ctx, attrs), do: Pools.create_pool(ctx.account, ctx.project, attrs)

  describe "create_pool/3" do
    test "stores a pool with defaults", ctx do
      assert {:ok, pool} =
               create(ctx, %{
                 "slug" => "rust-ci",
                 "setup" => ["curl -sSf https://sh.rustup.rs | sh -s -- -y"],
                 "max_members" => 4
               })

      assert pool.min_ready == 1
      assert pool.setup_version == 1
      assert pool.status == "active"
      assert pool.member_counts["idle"] == 0
      assert pool.project.slug == "app"

      assert {:ok, pool} = create(ctx, %{"slug" => "bare", "max_members" => 1})
      assert pool.setup == []
    end

    test "an explicit null min_ready or setup is the default, on create and replace", ctx do
      assert {:ok, pool} =
               create(ctx, %{
                 "slug" => "nulls",
                 "setup" => nil,
                 "min_ready" => nil,
                 "max_members" => 2
               })

      assert {pool.min_ready, pool.setup} == {1, []}

      assert {:ok, pool} =
               Pools.replace_pool(ctx.account, ctx.project, "nulls", %{
                 "slug" => "nulls",
                 "min_ready" => nil,
                 "max_members" => 3
               })

      assert {pool.min_ready, pool.max_members} == {1, 3}
    end

    test "slugs are unique per project, not per account", ctx do
      assert {:ok, _} = create(ctx, %{"slug" => "rust-ci", "max_members" => 2})
      assert {:error, changeset} = create(ctx, %{"slug" => "rust-ci", "max_members" => 2})
      assert errors_on(changeset).slug != []

      other = project_fixture(ctx.account, %{"slug" => "web"})

      assert {:ok, _} =
               Pools.create_pool(ctx.account, other, %{"slug" => "rust-ci", "max_members" => 2})
    end

    test "invalid slugs are 422", ctx do
      for slug <- ["", "Rust", "-x", "a/b", String.duplicate("a", 65)] do
        assert {:error, changeset} = create(ctx, %{"slug" => slug, "max_members" => 1})
        assert errors_on(changeset)[:slug], "accepted #{inspect(slug)}"
      end
    end

    test "capacity bounds", ctx do
      assert {:error, cs} = create(ctx, %{"slug" => "a", "min_ready" => 5, "max_members" => 4})
      assert errors_on(cs)[:min_ready]

      cap = Config.max_members_cap()
      assert {:error, cs} = create(ctx, %{"slug" => "a", "max_members" => cap + 1})
      assert errors_on(cs)[:max_members]

      assert {:error, cs} = create(ctx, %{"slug" => "a", "max_members" => 0})
      assert errors_on(cs)[:max_members]

      assert {:error, cs} = create(ctx, %{"slug" => "a", "max_members" => 2, "min_ready" => -1})
      assert errors_on(cs)[:min_ready]

      assert {:error, cs} = create(ctx, %{"slug" => "a"})
      assert errors_on(cs)[:max_members]

      assert {:ok, _} = create(ctx, %{"slug" => "a", "max_members" => cap, "min_ready" => 0})
    end

    test "idle_ttl_ms is optional (off by default) and bounded", ctx do
      assert {:ok, %{idle_ttl_ms: nil}} = create(ctx, %{"slug" => "off", "max_members" => 2})

      assert {:ok, %{idle_ttl_ms: 600_000}} =
               create(ctx, %{"slug" => "on", "max_members" => 2, "idle_ttl_ms" => 600_000})

      for bad <- [59_999, 2_592_000_001, "soon"] do
        assert {:error, cs} =
                 create(ctx, %{"slug" => "bad", "max_members" => 2, "idle_ttl_ms" => bad})

        assert errors_on(cs)[:idle_ttl_ms]
      end

      # A replacement without it switches it off again.
      assert {:ok, %{idle_ttl_ms: nil}} =
               Pools.replace_pool(ctx.account, ctx.project, "on", %{
                 "slug" => "on",
                 "max_members" => 2
               })
    end

    test "setup items follow the recipe phase rules", ctx do
      base = %{"slug" => "a", "max_members" => 1}

      assert {:error, cs} = create(ctx, Map.put(base, "setup", ["ok", "  "]))
      assert errors_on(cs)["setup[1]"] == ["can't be blank"]

      assert {:error, cs} = create(ctx, Map.put(base, "setup", [String.duplicate("x", 10_001)]))
      assert errors_on(cs)["setup[0]"]

      assert {:error, cs} = create(ctx, Map.put(base, "setup", List.duplicate("x", 501)))
      assert errors_on(cs)[:setup]

      assert {:error, cs} = create(ctx, Map.put(base, "setup", "echo"))
      assert errors_on(cs)[:setup]
    end

    test "placeholders and host steps are rejected", ctx do
      base = %{"slug" => "a", "max_members" => 1}

      assert {:error, cs} = create(ctx, Map.put(base, "setup", ["git checkout {{commit}}"]))
      assert [message] = errors_on(cs)["setup[0]"]
      assert message =~ "{{commit}}"

      assert {:error, cs} = create(ctx, Map.put(base, "setup", ["ok", %{"host" => "x"}, 3]))
      assert errors_on(cs)["setup[1]"]
      assert errors_on(cs)["setup[2]"]
    end

    test "only slug, setup, min_ready, and max_members are accepted", ctx do
      for key <- ["project", "org", "setup_version", "anything"] do
        attrs = %{"slug" => "a", "max_members" => 1, key => "x"}
        assert {:error, cs} = create(ctx, attrs)
        assert errors_on(cs)[key] == ["is not allowed in a pool body"]
      end

      assert Pools.list_pools(ctx.account, ctx.project) == []
    end

    test "a credential is required, after body validation", ctx do
      GoodFlows.Spry.delete_credential(ctx.account)

      assert {:error, cs} = create(ctx, %{"slug" => "BAD", "max_members" => 1})
      assert errors_on(cs)[:slug]

      assert {:error, {:unprocessable, message}} =
               create(ctx, %{"slug" => "a", "max_members" => 1})

      assert message =~ "Sprites credential must be configured"
      assert Pools.list_pools(ctx.account, ctx.project) == []
    end
  end

  describe "reads" do
    test "lists by slug and scopes by project and account", ctx do
      {:ok, _} = create(ctx, %{"slug" => "b", "max_members" => 1})
      {:ok, _} = create(ctx, %{"slug" => "a", "max_members" => 1})

      assert ctx.account |> Pools.list_pools(ctx.project) |> Enum.map(& &1.slug) == ["a", "b"]

      web = project_fixture(ctx.account, %{"slug" => "web"})
      assert Pools.list_pools(ctx.account, web) == []
      assert Pools.get_pool(ctx.account, web, "a") == {:error, :not_found}

      other = account_fixture()
      assert Pools.get_pool(other, ctx.project, "a") == {:error, :not_found}
      assert {:ok, %{slug: "a"}} = Pools.get_pool(ctx.account, ctx.project, "a")
    end

    test "member counts, status, and stale members", ctx do
      pool = pool_fixture(ctx.project, %{"slug" => "p"})
      idle = member_fixture(pool)
      _provisioning = member_fixture(pool, %{state: "provisioning", helper_version: nil})
      old_helper = member_fixture(pool, %{helper_version: "old"})

      assert {:ok, pool} = Pools.get_pool(ctx.account, ctx.project, "p")
      assert pool.member_counts["idle"] == 2
      assert pool.member_counts["provisioning"] == 1

      refute Pools.stale?(idle, pool)
      assert Pools.stale?(old_helper, pool)
      assert Pools.stale?(idle, %{pool | setup_version: 2})

      {:ok, _pool, members} = Pools.list_members(ctx.account, ctx.project, "p")
      assert length(members) == 3
      assert Enum.all?(members, &String.starts_with?(&1.name, "gfp-"))

      GoodFlows.Spry.delete_credential(ctx.account)

      assert {:ok, %{status: "credential_missing"}} =
               Pools.get_pool(ctx.account, ctx.project, "p")
    end
  end

  describe "replace_pool/4" do
    test "setup changes bump setup_version and clear the failure streak", ctx do
      pool = pool_fixture(ctx.project, %{"slug" => "p", "setup" => ["a"]})

      Repo.update_all(Ecto.Query.where(GoodFlows.Pools.Pool, id: ^pool.id),
        set: [provision_failures: 3, last_provision_error: "boom"]
      )

      assert {:ok, pool} =
               Pools.replace_pool(ctx.account, ctx.project, "p", %{
                 "slug" => "p",
                 "setup" => ["a"],
                 "max_members" => 2,
                 "min_ready" => 2
               })

      assert pool.setup_version == 1
      assert pool.provision_failures == 3

      assert {:ok, pool} =
               Pools.replace_pool(ctx.account, ctx.project, "p", %{
                 "slug" => "p",
                 "setup" => ["b"],
                 "max_members" => 2
               })

      assert pool.setup_version == 2
      assert pool.min_ready == 1
      assert pool.provision_failures == 0
      assert pool.last_provision_error == nil
    end

    test "cannot rename and leaves the pool unchanged", ctx do
      pool_fixture(ctx.project, %{"slug" => "rust-ci", "max_members" => 4})

      assert {:error, cs} =
               Pools.replace_pool(ctx.account, ctx.project, "rust-ci", %{
                 "slug" => "rust",
                 "max_members" => 2
               })

      assert errors_on(cs)[:slug]
      assert {:ok, %{max_members: 4}} = Pools.get_pool(ctx.account, ctx.project, "rust-ci")
    end

    test "missing pool and missing credential", ctx do
      assert Pools.replace_pool(ctx.account, ctx.project, "nope", %{}) == {:error, :not_found}

      pool_fixture(ctx.project, %{"slug" => "p"})
      GoodFlows.Spry.delete_credential(ctx.account)

      assert {:error, {:unprocessable, _}} =
               Pools.replace_pool(ctx.account, ctx.project, "p", %{
                 "slug" => "p",
                 "max_members" => 1
               })
    end
  end

  describe "delete_pool/3" do
    test "marks the pool deleting and hides it", ctx do
      pool = pool_fixture(ctx.project, %{"slug" => "p"})
      assert Pools.delete_pool(ctx.account, ctx.project, "p") == :ok
      assert Pools.get_pool(ctx.account, ctx.project, "p") == {:error, :not_found}
      assert Repo.reload!(pool).deleting_at
      # The slug is free again.
      assert {:ok, _} = create(ctx, %{"slug" => "p", "max_members" => 1})
    end

    test "refuses while a session is waiting or active", ctx do
      pool = pool_fixture(ctx.project, %{"slug" => "p"})
      session = session_fixture(pool, nil, %{status: "waiting"})
      assert Pools.delete_pool(ctx.account, ctx.project, "p") == {:error, :pool_in_use}

      Repo.update!(Ecto.Changeset.change(session, status: "active"))
      assert Pools.delete_pool(ctx.account, ctx.project, "p") == {:error, :pool_in_use}

      Repo.update!(Ecto.Changeset.change(session, status: "released"))
      assert Pools.delete_pool(ctx.account, ctx.project, "p") == :ok
    end
  end

  describe "projects with pools" do
    test "cannot be deleted, even while the pool is being deleted", ctx do
      pool = pool_fixture(ctx.project, %{"slug" => "p"})
      assert Projects.delete_project(ctx.account, ctx.project) == {:error, :has_pools}

      :ok = Pools.delete_pool(ctx.account, ctx.project, "p")
      assert Projects.delete_project(ctx.account, ctx.project) == {:error, :has_pools}

      Repo.delete!(pool)
      assert Projects.delete_project(ctx.account, ctx.project) == :ok
    end

    test "deleting the account cascades through every pool table", ctx do
      pool = pool_fixture(ctx.project, %{"slug" => "p"})
      member = member_fixture(pool)
      session = session_fixture(pool, nil)
      exec_fixture(session, member)

      Repo.delete!(ctx.account)
      refute Repo.reload(pool)
      refute Repo.reload(member)
    end

    test "member credential snapshots are encrypted and never inspected", ctx do
      pool = pool_fixture(ctx.project, %{"slug" => "p"})
      member = member_fixture(pool)

      %{rows: [[raw]]} =
        Repo.query!("SELECT credential_snapshot FROM pool_members WHERE id = $1", [
          Ecto.UUID.dump!(member.id)
        ])

      refute raw =~ token()
      assert Repo.get!(Member, member.id).credential_snapshot == token()
      refute inspect(member) =~ token()
    end
  end
end
