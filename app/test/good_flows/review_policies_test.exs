defmodule GoodFlows.ReviewPoliciesTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ReviewPolicies.Document

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "RP #{System.unique_integer()}"})
    owner = Accounts.get_account_user(user, account)
    {key, _} = api_key_fixture(owner, %{type: :private})
    member = account_user_fixture(account, user_fixture(), :member)
    %{owner: owner, member: member, key: key, project: project_fixture(account)}
  end

  defp body(previous, sections \\ %{}, note \\ nil) do
    base = %{
      "previous_version" => previous,
      "policy" => Map.merge(%{"format" => "review-policy/1"}, sections)
    }

    if note, do: Map.put(base, "note", note), else: base
  end

  defp write(ctx, body), do: ReviewPolicies.write(ctx.project, ctx.owner, ctx.key, body)

  test "a project without a policy has version 0 and no history", ctx do
    assert %{version: 0, document: document, note: nil, inserted_at: nil} =
             ReviewPolicies.current(ctx.project)

    assert document == Document.default()
    assert {:ok, %{version: 0}} = ReviewPolicies.get_version(ctx.project, 0)

    assert {:ok, %{versions: [], next_cursor: nil}} =
             ReviewPolicies.list_versions(ctx.project, %{})

    assert ReviewPolicies.compiled(ctx.project.id).version == 0
  end

  test "writes create numbered versions; retries return the current one; stale is a conflict",
       ctx do
    assert {:ok, :created, v1} = write(ctx, body(0, %{}, "Require ci"))
    assert %{version: 1, previous_version: 0, note: "Require ci"} = v1
    assert v1.account_user.user_id == ctx.owner.user_id

    assert {:ok, :retry, %{version: 1}} = write(ctx, body(0, %{}, "Require ci"))
    assert {:error, :policy_version_conflict} = write(ctx, body(0, %{}, "Other"))

    assert {:ok, :created, %{version: 2}} =
             write(ctx, body(1, %{"size" => %{"max_changed_files" => 3}}))

    assert {:ok, :created, %{version: 3}} = write(ctx, body(2))

    assert {:error, :policy_version_conflict} =
             write(ctx, body(1, %{"size" => %{"max_changed_files" => 9}}))

    assert ReviewPolicies.current(ctx.project).version == 3

    assert {:ok, %{document: %{"size" => %{"max_changed_files" => 3}}}} =
             ReviewPolicies.get_version(ctx.project, 2)

    assert {:error, :not_found} = ReviewPolicies.get_version(ctx.project, 9)
    assert ReviewPolicies.compiled(ctx.project.id).effective["size"]["max_changed_lines"] == 1500
  end

  test "only owners and admins write, and invalid bodies store nothing", ctx do
    assert {:error, :forbidden} = ReviewPolicies.write(ctx.project, ctx.member, ctx.key, body(0))
    assert {:error, {:invalid_body, %{"policy" => _}}} = write(ctx, body(0, %{"rules" => []}))
    assert ReviewPolicies.current(ctx.project).version == 0
  end

  describe "scenarios.diff_only" do
    test "is accepted and stored as written", ctx do
      assert {:ok, :created, v1} =
               write(ctx, body(0, %{"scenarios" => %{"diff_only" => "weakening"}}))

      assert v1.document["scenarios"] == %{"diff_only" => "weakening"}

      assert ReviewPolicies.compiled(ctx.project.id).effective["scenarios"]["diff_only"] ==
               "weakening"
    end

    test "cannot block, and a refused write stores nothing", ctx do
      assert {:error, {:invalid_body, errors}} =
               write(ctx, body(0, %{"scenarios" => %{"diff_only" => "blocked"}}))

      assert errors["policy.scenarios.diff_only"]
      assert ReviewPolicies.current(ctx.project).version == 0
    end

    test "an older policy and version 0 read needs_review", ctx do
      assert ReviewPolicies.current(ctx.project).document["scenarios"]["diff_only"] ==
               "needs_review"

      assert "scenarios.diff_only" in Document.active_settings()

      assert {:ok, :created, v1} =
               write(ctx, body(0, %{"scenarios" => %{"require_approved_intent" => true}}))

      refute Map.has_key?(v1.document["scenarios"], "diff_only")
      assert Document.effective(v1.document)["scenarios"]["diff_only"] == "needs_review"
    end
  end

  test "lists newest first with keyset pages", ctx do
    for n <- 0..2, do: {:ok, :created, _} = write(ctx, body(n, %{}, "v#{n + 1}"))

    {:ok, page} = ReviewPolicies.list_versions(ctx.project, %{"limit" => "2"})
    assert Enum.map(page.versions, & &1.version) == [3, 2]

    {:ok, last} =
      ReviewPolicies.list_versions(ctx.project, %{"limit" => "2", "cursor" => page.next_cursor})

    assert Enum.map(last.versions, & &1.version) == [1]
    assert last.next_cursor == nil

    assert {:error, %Ecto.Changeset{}} =
             ReviewPolicies.list_versions(ctx.project, %{"limit" => "0"})

    assert {:error, %Ecto.Changeset{}} =
             ReviewPolicies.list_versions(ctx.project, %{"cursor" => "nope"})
  end
end
