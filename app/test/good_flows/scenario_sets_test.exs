defmodule GoodFlows.ScenarioSetsTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ScenarioSets
  alias GoodFlows.ScenarioSets.{Decision, Version}

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "SS #{System.unique_integer()}"})
    owner = Accounts.get_account_user(user, account)
    {key, _} = api_key_fixture(owner, %{type: :private})
    member = account_user_fixture(account, user_fixture(), :member)
    {member_key, _} = api_key_fixture(member, %{type: :private})
    project = project_fixture(account)

    {:ok, cr} =
      ChangeRequests.create(account, project, key, %{
        "title" => "Export",
        "source_branch" => "feat/export",
        "openspec_change" => "add-export"
      })

    %{
      account: account,
      owner: owner,
      key: key,
      member: member,
      member_key: member_key,
      project: project,
      cr: cr
    }
  end

  defp upload!(ctx, body, cr \\ nil) do
    {:ok, status, version} = ScenarioSets.upload(cr || ctx.cr, ctx.key, body)
    {status, version}
  end

  defp approve(ctx, digest, who \\ :owner),
    do: decide(ctx, :approve, %{"digest" => digest}, who)

  defp reject(ctx, digest, note \\ "S2 tests the wrong path", who \\ :owner),
    do: decide(ctx, :reject, %{"digest" => digest, "note" => note}, who)

  defp decide(ctx, kind, body, who) do
    {au, key} = if who == :owner, do: {ctx.owner, ctx.key}, else: {ctx.member, ctx.member_key}
    ScenarioSets.decide(Repo.reload!(ctx.cr), au, key, kind, body)
  end

  defp approved?(ctx, version),
    do: ScenarioSets.approved?(version, ScenarioSets.approved_digests(ctx.cr))

  defp policy!(ctx, scenarios) do
    {:ok, :created, _} =
      ReviewPolicies.write(ctx.project, ctx.owner, ctx.key, %{
        "previous_version" => ReviewPolicies.current(ctx.project).version,
        "policy" => %{"format" => "review-policy/1", "scenarios" => scenarios}
      })
  end

  describe "upload" do
    test "stores content byte for byte, versions, duplicates and reverts", ctx do
      v1_body = set_body(intent_fm("add-export"), body: "# QA  \r\nsteps  \r\n")
      assert {:created, v1} = upload!(ctx, v1_body)
      assert v1.version == 1
      assert v1.content == v1_body["content"]
      assert v1.digest == digest_of(v1_body)
      assert v1.account_user_id == ctx.owner.id and v1.api_key_id == ctx.key.id

      assert {:duplicate, %Version{version: 1}} = upload!(ctx, v1_body)

      v2_body = %{v1_body | "content" => v1_body["content"] <> "\n"}
      assert {:created, %Version{version: 2, digest: d2}} = upload!(ctx, v2_body)
      refute d2 == v1.digest

      assert {:created, %Version{version: 3, digest: d3}} = upload!(ctx, v1_body)
      assert d3 == v1.digest

      assert {:ok, %Version{version: 1}} = ScenarioSets.get_version(ctx.cr, "intent", 1)
      assert {:error, :not_found} = ScenarioSets.get_version(ctx.cr, "intent", 4)
    end

    test "the intent change must equal the linked change", ctx do
      assert {:error, {:invalid_body, %{"content.change" => _}}} =
               ScenarioSets.upload(ctx.cr, ctx.key, set_body(intent_fm("add-import")))

      {:ok, unlinked} =
        ChangeRequests.create(ctx.account, ctx.project, ctx.key, %{
          "title" => "x",
          "source_branch" => "b"
        })

      assert {:error, {:invalid_body, %{"content.change" => _}}} =
               ScenarioSets.upload(unlinked, ctx.key, set_body(intent_fm("add-export")))

      assert {:created, %Version{source: "diff"}} =
               upload!(ctx, set_body(diff_fm("abc1234")), unlinked)
    end

    test "closed change requests refuse uploads", ctx do
      {:ok, closed} = ChangeRequests.transition(ctx.cr, ctx.key, :close)

      assert {:error, :not_active} =
               ScenarioSets.upload(closed, ctx.key, set_body(intent_fm("add-export")))

      assert Repo.aggregate(Version, :count) == 0
    end
  end

  describe "decisions" do
    setup ctx do
      body = set_body(intent_fm("add-export"))
      {:created, version} = upload!(ctx, body)
      %{v1: version, d1: version.digest}
    end

    test "schema: decision rows are ordered and indexed", ctx do
      assert {:ok, :created, %Decision{decision: "approve", channel: "cli", note: nil} = d} =
               approve(ctx, ctx.d1)

      assert d.account_user_id == ctx.owner.id and d.api_key_id == ctx.key.id
      assert d.digest == ctx.d1

      %{rows: [[index]]} =
        Repo.query!(
          "SELECT indexdef FROM pg_indexes WHERE indexname = 'scenario_set_decisions_digest_index'"
        )

      assert index =~ "(change_request_id, digest, inserted_at)"
    end

    test "approve, repeat, reject after approve, approve after reject", ctx do
      assert {:ok, :created, _} = approve(ctx, ctx.d1)
      assert approved?(ctx, ctx.v1)
      assert {:ok, :retry, _} = approve(ctx, ctx.d1)
      assert Repo.aggregate(Decision, :count) == 1

      assert {:ok, :created, %Decision{decision: "reject", note: "S2 tests the wrong path"}} =
               reject(ctx, ctx.d1, "S2 tests the wrong path", :member)

      refute approved?(ctx, ctx.v1)

      assert {:ok, :created, _} = approve(ctx, ctx.d1)
      assert approved?(ctx, ctx.v1)
      assert length(ScenarioSets.decisions(ctx.cr, ctx.d1)) == 3
    end

    test "a repeated reject is a retry only with the same note", ctx do
      assert {:ok, :created, _} = reject(ctx, ctx.d1, "first")
      assert {:ok, :retry, _} = reject(ctx, ctx.d1, "first")
      assert {:ok, :created, %Decision{note: "second"}} = reject(ctx, ctx.d1, "second")
      assert Repo.aggregate(Decision, :count) == 2
    end

    test "reject needs a note; stale and unknown digests are 409", ctx do
      assert {:error, {:invalid_body, %{"note" => _}}} =
               decide(ctx, :reject, %{"digest" => ctx.d1}, :owner)

      assert {:error, :stale_digest} = approve(ctx, String.duplicate("a", 64))

      {:created, _} = upload!(ctx, set_body(intent_fm("add-export"), body: "edited\n"))
      assert {:error, :stale_digest} = approve(ctx, ctx.d1)
      assert Repo.aggregate(Decision, :count) == 0
    end

    test "closed and merged change requests refuse decisions", ctx do
      {:ok, _closed} = ChangeRequests.transition(ctx.cr, ctx.key, :close)
      assert {:error, :not_active} = approve(ctx, ctx.d1)

      policy!(ctx, %{"approver" => "other_member"})
      assert {:error, :not_active} = approve(ctx, ctx.d1)
      policy!(ctx, %{"approver" => "any"})

      {:ok, _} = ChangeRequests.transition(Repo.reload!(ctx.cr), ctx.key, :reopen)

      {:ok, _merged} =
        ChangeRequests.report_merge(Repo.reload!(ctx.cr), ctx.key, %{
          "merged_commit" => sha(9),
          "target_branch" => "main"
        })

      assert {:error, :not_active} = approve(ctx, ctx.d1)
      assert Repo.aggregate(Decision, :count) == 0
    end

    test "default policy lets the author approve", ctx do
      assert {:ok, :created, _} = approve(ctx, ctx.d1)
    end

    test "approver any, other_member and admin; both decisions", ctx do
      policy!(ctx, %{"approver" => "other_member"})
      assert {:error, :forbidden} = approve(ctx, ctx.d1)
      assert {:error, :forbidden} = reject(ctx, ctx.d1)
      assert {:ok, :created, _} = approve(ctx, ctx.d1, :member)

      policy!(ctx, %{"approver" => "admin"})
      assert {:error, :forbidden} = reject(ctx, ctx.d1, "no", :member)
      assert {:ok, :created, _} = reject(ctx, ctx.d1)

      policy!(ctx, %{"approver" => "any"})
      assert {:ok, :created, _} = approve(ctx, ctx.d1, :member)
    end

    test "approval follows the digest: push, edit, revert", ctx do
      {:ok, :created, _} = approve(ctx, ctx.d1)

      {:ok, _, cr} = ChangeRequests.report_git_facts(ctx.cr, ctx.key, git_facts(sha(5)))
      assert approved?(%{ctx | cr: cr}, ctx.v1)

      {:created, v2} = upload!(ctx, set_body(intent_fm("add-export"), body: "edit\n"))
      refute approved?(ctx, v2)

      {:created, v3} = upload!(ctx, set_body(intent_fm("add-export")))
      assert v3.digest == ctx.d1
      assert approved?(ctx, v3)
    end
  end

  describe "diff baseline and accepted" do
    setup ctx do
      {:ok, unlinked} =
        ChangeRequests.create(ctx.account, ctx.project, ctx.key, %{
          "title" => "Diff",
          "source_branch" => "feat/diff"
        })

      versions =
        for n <- 1..3 do
          {:created, v} = upload!(ctx, set_body(diff_fm(sha(n), [scenario("D1")])), unlinked)
          v
        end

      %{unlinked: unlinked, versions: versions}
    end

    defp insert_decision!(ctx, digest, decision) do
      Repo.insert!(%Decision{
        change_request_id: ctx.unlinked.id,
        digest: digest,
        decision: decision,
        note: if(decision == "reject", do: "S3 must stay a Must"),
        channel: "cli",
        account_user_id: ctx.owner.id,
        api_key_id: ctx.key.id
      })
    end

    defp baseline_version(ctx),
      do: ScenarioSets.baseline(ctx.unlinked, ScenarioSets.approved_digests(ctx.unlinked)).version

    test "no decision: version 1", ctx do
      assert baseline_version(ctx) == 1
      assert ScenarioSets.baseline(ctx.cr, ScenarioSets.approved_digests(ctx.cr)) == nil
    end

    test "approve then reject: the latest decision decides", ctx do
      [_v1, v2, _v3] = ctx.versions
      insert_decision!(ctx, v2.digest, "approve")
      insert_decision!(ctx, v2.digest, "reject")

      assert baseline_version(ctx) == 1
      refute ScenarioSets.accepted?(v2, ScenarioSets.approved_digests(ctx.unlinked))
    end
  end

  describe "compare" do
    defp v(scenarios, salts \\ %{}),
      do: set_body(intent_fm("add-export", scenarios), salts: salts)

    test "nothing approved: everything is added", ctx do
      {:created, _} = upload!(ctx, v([scenario("S1"), scenario("S2")]))
      {:ok, cmp} = ScenarioSets.compare(ctx.cr, "intent", %{})
      assert cmp.from == nil
      assert Enum.map(cmp.changes, &{&1.id, &1.change}) == [{"S1", "added"}, {"S2", "added"}]
    end

    test "weakening first, then removals, changed, added; unchanged omitted", ctx do
      from =
        v([
          scenario("S1"),
          scenario("S2"),
          scenario("S3"),
          scenario("S4"),
          scenario("S5", "should"),
          scenario("S7", "could")
        ])

      {:created, v1} = upload!(ctx, from)
      {:ok, :created, _} = approve(ctx, v1.digest)

      to =
        v(
          [
            scenario("S1"),
            scenario("S2"),
            scenario("S3", "should"),
            scenario("S5", "could"),
            scenario("S6")
          ],
          %{"S2" => "x"}
        )

      {:created, _} = upload!(ctx, to)
      {:ok, cmp} = ScenarioSets.compare(ctx.cr, "intent", %{})
      assert cmp.from.version == 1 and cmp.to.version == 2

      assert cmp.changes == [
               %{
                 id: "S3",
                 change: "demoted",
                 weakening: true,
                 from_priority: "must",
                 to_priority: "should"
               },
               %{
                 id: "S4",
                 change: "removed",
                 weakening: true,
                 from_priority: "must",
                 to_priority: nil
               },
               %{
                 id: "S7",
                 change: "removed",
                 weakening: false,
                 from_priority: "could",
                 to_priority: nil
               },
               %{
                 id: "S2",
                 change: "changed",
                 weakening: false,
                 from_priority: "must",
                 to_priority: "must"
               },
               %{
                 id: "S5",
                 change: "changed",
                 weakening: false,
                 from_priority: "should",
                 to_priority: "could"
               },
               %{
                 id: "S6",
                 change: "added",
                 weakening: false,
                 from_priority: nil,
                 to_priority: "must"
               }
             ]
    end

    test "diff compares with the previous version; explicit from/to; unknown 404", ctx do
      {:ok, unlinked} =
        ChangeRequests.create(ctx.account, ctx.project, ctx.key, %{
          "title" => "x",
          "source_branch" => "b"
        })

      {:created, _} = upload!(ctx, set_body(diff_fm("abc1234", [scenario("D1")])), unlinked)

      {:created, _} =
        upload!(ctx, set_body(diff_fm("abc1234", [scenario("D1"), scenario("D2")])), unlinked)

      {:ok, cmp} = ScenarioSets.compare(unlinked, "diff", %{})
      assert Enum.map(cmp.changes, & &1.id) == ["D2"]

      {:ok, cmp} = ScenarioSets.compare(unlinked, "diff", %{"from" => "2", "to" => "1"})
      assert [%{id: "D2", change: "removed", weakening: true}] = cmp.changes

      assert {:error, :not_found} = ScenarioSets.compare(unlinked, "diff", %{"to" => "9"})
      assert {:error, :not_found} = ScenarioSets.compare(ctx.cr, "diff", %{})
    end
  end
end
