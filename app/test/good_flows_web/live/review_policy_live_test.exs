defmodule GoodFlowsWeb.ReviewPolicyLiveTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import Phoenix.LiveViewTest

  alias GoodFlows.ReviewPolicies

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture()
    member = account_user_fixture(account, user, :member)
    admin = account_user_fixture(account, user_fixture(%{email: "admin@example.com"}), :admin)
    {key, _token} = api_key_fixture(admin, %{type: :private})
    project = project_fixture(account, %{slug: "web"})
    %{account: account, member: member, admin: admin, key: key, project: project}
  end

  defp policy_path(ctx, query \\ ""),
    do: "/dashboard/accounts/#{ctx.account.id}/projects/web/review-policy#{query}"

  defp write!(ctx, previous, sections, note) do
    {:ok, :created, version} =
      ReviewPolicies.write(ctx.project, ctx.admin, ctx.key, %{
        "previous_version" => previous,
        "policy" => Map.merge(%{"format" => "review-policy/1"}, sections),
        "note" => note
      })

    version
  end

  test "a member sees the default policy of a project that never wrote one", ctx do
    {:ok, view, _html} = live(ctx.conn, policy_path(ctx))

    assert has_element?(view, "#policy-version", "Version 0")
    assert has_element?(view, "#default-policy-notice")
    assert has_element?(view, "#setting-claims-min_proof_level", "ran")
    assert has_element?(view, "#setting-claims-min_proof_level", "default")
    assert has_element?(view, "#no-policy-paths")
    assert has_element?(view, "#policy-history-0")
  end

  test "the current version shows written settings, effective defaults and history", ctx do
    write!(ctx, 0, %{"size" => %{"max_changed_files" => 10}}, "Tighter size")

    write!(
      ctx,
      1,
      %{"paths" => [%{"glob" => "app/priv/**", "outcome" => "blocked"}]},
      "Guard migrations"
    )

    {:ok, view, _html} = live(ctx.conn, policy_path(ctx))

    assert has_element?(view, "#policy-version", "Version 2")
    refute has_element?(view, "#default-policy-notice")
    assert has_element?(view, "#policy-written-by", "admin@example.com")
    assert has_element?(view, "#policy-note", "Guard migrations")
    assert has_element?(view, "#policy-path-0", "app/priv/**")
    assert has_element?(view, "#policy-path-0", "blocked")
    # Version 2 does not carry version 1's size setting: each version is whole.
    assert has_element?(view, "#setting-size-max_changed_files", "40")
    assert has_element?(view, "#setting-size-max_changed_files", "default")

    for n <- [2, 1, 0], do: assert(has_element?(view, "#policy-history-#{n}"))

    view |> element("#policy-history-1 a") |> render_click()

    assert_patch(view, policy_path(ctx, "?version=1"))
    assert has_element?(view, "#policy-version", "Version 1")
    assert has_element?(view, "#old-version-notice")
    assert has_element?(view, "#setting-size-max_changed_files", "10")
    refute has_element?(view, "#setting-size-max_changed_files", "default")
  end

  test "the header switches between versions", ctx do
    write!(ctx, 0, %{"size" => %{"max_changed_files" => 10}}, "Tighter size")
    write!(ctx, 1, %{"size" => %{"max_changed_files" => 20}}, "Looser size")

    {:ok, view, _html} = live(ctx.conn, policy_path(ctx))

    assert has_element?(view, "#newer-version[disabled]")
    view |> form("#version-form", %{"version" => "0"}) |> render_change()
    assert_patch(view, policy_path(ctx, "?version=0"))
    assert has_element?(view, "#policy-version", "Version 0")
    assert has_element?(view, "#older-version[disabled]")

    view |> element("#newer-version") |> render_click()
    assert_patch(view, policy_path(ctx, "?version=1"))
    assert has_element?(view, "#setting-size-max_changed_files", "10")

    view |> element("#newer-version") |> render_click()
    assert_patch(view, policy_path(ctx))
    assert has_element?(view, "#policy-version", "Version 2")
    assert has_element?(view, "#setting-size-max_changed_files", "20")

    view |> element("#older-version") |> render_click()
    assert_patch(view, policy_path(ctx, "?version=1"))
  end

  test "an unknown version falls back to the current one", ctx do
    target = policy_path(ctx)

    assert {:error, {:live_redirect, %{to: ^target, flash: %{"error" => error}}}} =
             live(ctx.conn, policy_path(ctx, "?version=9"))

    assert error == "Policy version 9 not found"
  end

  test "the project overview links to the policy", ctx do
    {:ok, view, _html} = live(ctx.conn, "/dashboard/accounts/#{ctx.account.id}/projects/web")

    assert {:ok, policy, _html} =
             view |> element("#review-policy-link") |> render_click() |> follow_redirect(ctx.conn)

    assert has_element?(policy, "#policy-version", "Version 0")
  end

  test "a project of another account redirects to the projects page", ctx do
    other = project_fixture(account_fixture(), %{slug: "elsewhere"})

    assert {:error, {:live_redirect, %{flash: %{"error" => "Project not found"}}}} =
             live(
               ctx.conn,
               "/dashboard/accounts/#{ctx.account.id}/projects/#{other.slug}/review-policy"
             )
  end
end
