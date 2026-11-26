defmodule GoodFlowsWeb.ChangeRequestLiveTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.MergeFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures
  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.Verdict
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Repo
  alias GoodFlows.Review
  alias GoodFlows.Review.Answer
  alias GoodFlows.ScenarioSets

  setup :api_setup
  setup :register_and_log_in_user

  setup %{account: account, user: user} do
    membership = account_user_fixture(account, user, :member)
    project = project_fixture(account, %{slug: "web", default_branch: "main"})
    %{membership: membership, project: project, slug: project.slug}
  end

  defp list_path(ctx, query \\ ""),
    do: "/dashboard/accounts/#{ctx.account.id}/projects/#{ctx.slug}/change-requests" <> query

  defp show_path(ctx, number), do: list_path(ctx) <> "/#{number}"

  defp create!(ctx, attrs \\ %{}) do
    body = Map.merge(%{"title" => "Add login", "source_branch" => "feat/login"}, attrs)
    {:ok, cr} = ChangeRequests.create(ctx.account, ctx.project, ctx.sk_key, body)
    cr
  end

  defp ready!(ctx, number),
    do: ctx.sk_conn |> post(cr_path(ctx.slug, number, "/ready")) |> json_response(200)

  defp close!(ctx, number),
    do: ctx.sk_conn |> post(cr_path(ctx.slug, number, "/close")) |> json_response(200)

  defp merge!(ctx, number),
    do: ctx.sk_conn |> merged(ctx.slug, number, sha(0xC1)) |> json_response(200)

  defp one_way!(ctx, number, head, overrides \\ %{}) do
    facts!(ctx.sk_conn, ctx.slug, number, head)

    claims!(
      ctx.sk_conn,
      ctx.slug,
      number,
      head,
      Map.merge(%{"cr" => number, "door" => "one_way"}, overrides)
    )
  end

  defp item_id(ctx, number, kind),
    do:
      "item-" <>
        String.replace(item!(packet(ctx.sk_conn, ctx.slug, number), kind)["id"], ":", "-")

  # Broadcasts a project event as the Listener does after a commit (the
  # SQL sandbox never commits), then waits for the debounced refresh.
  defp project_event(view, ctx) do
    :erlang.trace(view.pid, true, [:receive])

    Phoenix.PubSub.broadcast(
      GoodFlows.PubSub,
      ProjectEvents.topic(ctx.project.id),
      {:project_event, ctx.project.id}
    )

    assert_receive {:trace, _pid, :receive, :refresh}, 2_000
    :erlang.trace(view.pid, false, [:receive])
    render(view)
  end

  defp row_numbers(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#change-requests a[id^=change-request-link-]")
    |> LazyHTML.attribute("id")
    |> Enum.map(fn "change-request-link-" <> n -> String.to_integer(n) end)
  end

  describe "list" do
    test "a member sees active change requests, newest first", ctx do
      [closed, merged, open, draft] = for _ <- 1..4, do: create!(ctx)
      close!(ctx, closed.number)
      merge!(ctx, merged.number)
      ready!(ctx, open.number)

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert row_numbers(view) == [draft.number, open.number]
      assert has_element?(view, "#filter-active[aria-current=page]")

      assert has_element?(
               view,
               "#change-request-link-#{draft.number}[href='#{show_path(ctx, draft.number)}']"
             )

      refute has_element?(view, "#load-more")
    end

    test "?state=closed lists only closed change requests", ctx do
      [closed, _open] = for _ <- 1..2, do: create!(ctx)
      close!(ctx, closed.number)

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?state=closed"))

      assert row_numbers(view) == [closed.number]
      assert has_element?(view, "#filter-closed[aria-current=page]")
    end

    test "Load more shows all 51, and keeps them after a refresh", ctx do
      for _ <- 1..51, do: create!(ctx)
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert length(row_numbers(view)) == 50
      view |> element("#load-more") |> render_click()
      assert row_numbers(view) == Enum.to_list(51..1//-1)
      refute has_element?(view, "#load-more")

      _ = project_event(view, ctx)
      assert length(row_numbers(view)) == 51
      assert has_element?(view, "#filter-active[aria-current=page]")
    end

    test "an empty filter names itself and offers all", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?state=merged"))

      assert has_element?(view, "#change-requests-empty", "No merged change requests")
      view |> element("#empty-show-all") |> render_click()
      assert has_element?(view, "#change-requests-empty", "No change requests yet")
    end

    test "a project of another account redirects with Project not found", ctx do
      other = project_fixture(ctx.other_account, %{slug: "elsewhere"})
      path = "/dashboard/accounts/#{ctx.account.id}/projects/#{other.slug}/change-requests"

      assert {:error, {:live_redirect, %{to: to, flash: %{"error" => "Project not found"}}}} =
               live(ctx.conn, path)

      assert to == "/dashboard/accounts/#{ctx.account.id}/projects"
    end

    test "merged and closed rows ignore a later stored verdict but show its review count",
         ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"evidence" => %{"required_workflows" => ["ci"]}})
      blocked = create!(ctx)
      facts!(ctx.sk_conn, ctx.slug, blocked.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, blocked.number, sha(1), %{"cr" => blocked.number})

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{ctx.slug}/workflow-runs", run_document(sha(1), "failed"))
        |> json_response(201)

      assert verdict(ctx.sk_conn, ctx.slug, blocked.number)["state"] == "blocked"
      merge!(ctx, blocked.number)
      clean = create!(ctx)
      facts!(ctx.sk_conn, ctx.slug, clean.number, sha(2))
      claims!(ctx.sk_conn, ctx.slug, clean.number, sha(2), %{"cr" => clean.number})

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{ctx.slug}/workflow-runs", run_document(sha(2), "passed"))
        |> json_response(201)

      assert verdict(ctx.sk_conn, ctx.slug, clean.number)["state"] == "mergeable"
      merge!(ctx, clean.number)
      closed = create!(ctx)
      close!(ctx, closed.number)
      Repo.update_all(Verdict, set: [state: "mergeable", review: %{"items" => 2, "cleared" => 2}])

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?state=merged"))
      assert has_element?(view, "#verdict-#{blocked.number}", "Blocked")
      assert has_element?(view, "#review-count-#{blocked.number}", "2 of 2")
      refute has_element?(view, "#verdict-#{clean.number}")

      assert has_element?(
               view,
               "#merged-unmergeable-#{blocked.number}",
               "Merged without a mergeable verdict"
             )

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?state=closed"))
      assert row_numbers(view) == [closed.number]
      refute has_element?(view, "#verdict-#{closed.number}")
      assert has_element?(view, "#review-count-#{closed.number}", "2 of 2")
    end

    test "active rows show the stored review count, and 0 of 0 when nothing is counted", ctx do
      fresh = create!(ctx)
      counted = create!(ctx)

      Repo.update_all(from(v in Verdict, where: v.change_request_id == ^counted.id),
        set: [review: %{"items" => 4, "cleared" => 2}]
      )

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))
      assert row_numbers(view) == [counted.number, fresh.number]
      assert has_element?(view, "#review-count-#{fresh.number}", "0 of 0")
      assert has_element?(view, "#review-count-#{counted.number}", "2 of 4")
    end
  end

  describe "detail" do
    test "needs_review explains each reason, with no subject for []", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "paths" => [%{"glob" => "priv/repo/migrations/**", "outcome" => "needs_review"}]
      })

      cr = create!(ctx)

      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1),
        files: [file("priv/repo/migrations/1.exs")]
      )

      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number, "door" => "one_way"})

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#header-verdict", "Needs review")
      door = "#reasons li[data-rule=one_way_door]"
      assert has_element?(view, door, "The claims call this change a one-way door")
      refute has_element?(view, door <> " [id$=-subject]")

      path = "#reasons li[data-rule=path_match]"
      assert has_element?(view, path, "The diff touches paths matching priv/repo/migrations/**")
      assert has_element?(view, path <> " [id$=-subject]", "priv/repo/migrations/**")
    end

    test "mergeable says nothing blocks merging; no head says so", ctx do
      cr = create!(ctx)
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#no-head", "No head yet")

      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number})
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#header-verdict", "Mergeable")

      assert has_element?(
               view,
               "#no-reasons",
               "Nothing blocks merging at commit #{String.slice(sha(1), 0, 7)}."
             )

      merge!(ctx, cr.number)
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(
               view,
               "#no-reasons",
               "Nothing blocked the merge at commit #{String.slice(sha(1), 0, 7)}."
             )
    end

    test "an unknown or invalid number redirects with Change request not found", ctx do
      for _ <- 1..3, do: create!(ctx)

      for number <- ["999", "0", "abc"] do
        assert {:error, {:live_redirect, %{flash: %{"error" => "Change request not found"}}}} =
                 live(ctx.conn, show_path(ctx, number))
      end
    end

    test "review items: answered and unanswered, cleared count, earlier heads hidden", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "paths" => [%{"glob" => "priv/**", "outcome" => "needs_review"}]
      })

      cr = create!(ctx)
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1), files: [file("priv/a.sql")])
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number, "door" => "one_way"})
      door = item!(packet(ctx.sk_conn, ctx.slug, cr.number), "one_way_door")

      _ =
        ctx.sk_conn
        |> answer(ctx.slug, cr.number, door["id"], %{"head" => sha(1), "answer" => "approve"})
        |> json_response(201)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      door_id = item_id(ctx, cr.number, "one_way_door")
      path_id = item_id(ctx, cr.number, "sensitive_path")
      assert has_element?(view, "#review-cleared", "1 of 2 cleared")
      assert has_element?(view, "##{door_id}-answer", "Approved by")
      assert has_element?(view, "##{path_id}-unanswered", "No answer at this head")

      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(2), files: [file("priv/a.sql")])
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(2), %{"cr" => cr.number, "door" => "one_way"})
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "##{door_id}-unanswered")
      assert has_element?(view, "#review-cleared", "0 of 2 cleared")
    end

    test "each open item shows its own risk and location", ctx do
      cr = create!(ctx)
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1), files: [file("lib/a.ex")])

      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{
        "cr" => cr.number,
        "left_open" => [
          %{
            "risk" => "Restart loses todos",
            "location" => "app/todos.py:32",
            "affected" => "ops"
          },
          %{"risk" => "Ids can collide", "location" => "app/todos.py:51", "affected" => "users"}
        ],
        "questions" => [
          %{
            "id" => "1",
            "text" => "Keep ids?",
            "options" => ["Yes", "No"],
            "recommendation" => "Yes"
          }
        ]
      })

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      items = packet(ctx.sk_conn, ctx.slug, cr.number)["items"]
      open = Enum.filter(items, &(&1["kind"] == "open_item"))

      expected = [
        {"Restart loses todos", "app/todos.py:32"},
        {"Ids can collide", "app/todos.py:51"}
      ]

      assert length(open) == 2

      for {item, {risk, location}} <- Enum.zip(open, expected) do
        dom = "#item-#{String.replace(item["id"], ":", "-")}-risk"
        assert has_element?(view, dom, risk)
        assert has_element?(view, dom, location)
      end

      subject = "#reasons [data-rule='open_items'] [id$='-subject'] a[href='#review-panel']"
      assert has_element?(view, subject, "1 question · 2 open risks")
      refute has_element?(view, "#reasons", "Ids can collide")
    end

    test "failed and not run scenario items show the run's reason and failed step", ctx do
      cr = create!(ctx, %{"change_id" => "add-export"})
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number})
      fm = intent_fm("add-export", [scenario("S1", "should"), scenario("S2", "should")])

      digest =
        ctx.sk_conn
        |> post_json(cr_path(ctx.slug, cr.number, "/scenario-sets"), set_body(fm))
        |> json_response(201)
        |> get_in(["data", "digest"])

      _ =
        ctx.sk_conn
        |> post_json(cr_path(ctx.slug, cr.number, "/scenario-sets/intent/approvals"), %{
          "digest" => digest
        })
        |> json_response(201)

      results = [
        %{result("S1", "failed") | "failed_step" => "step 3", "reason" => "Export button 404s"},
        %{result("S2", "not_run") | "reason" => "Needs a second account"}
      ]

      run!(ctx, digest, results, "2026-11-20T10:00:00Z")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      failed = "##{item_id(ctx, cr.number, "failed_scenario")}-result"
      not_run = "##{item_id(ctx, cr.number, "not_run")}-result"
      assert has_element?(view, failed, "Export button 404s")
      assert has_element?(view, failed, "Failed at step 3")
      assert has_element?(view, not_run, "Needs a second account")
      refute has_element?(view, not_run, "Failed at")

      assert has_element?(
               view,
               "#reasons [data-rule=should_failed] a[href='#scenario-intent-S1']",
               "Intent set · scenario S1: Scenario S1"
             )
    end

    test "a merged change request shows no items, the notice and Merged without a lease", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      merge!(ctx, cr.number)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      refute has_element?(view, "#review-panel")
      refute has_element?(view, "button[phx-click=open_answer]")
      assert has_element?(view, "#merged-unmergeable-notice", "Needs review")
      assert has_element?(view, "#merged-without-lease", "Merged without a lease")
      refute has_element?(view, "#header-verdict")
      assert has_element?(view, "#verdict-panel", "Verdict at merge")
      assert has_element?(view, "#evidence-panel", "Last computed evidence")
      assert has_element?(view, "#evidence-frozen", "merged")
      assert has_element?(view, "#evidence-panel", "Review count")
      assert has_element?(view, "#evidence-review-count", "0 of 1 cleared")
    end

    test "a closed change request shows its last review count as evidence", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      close!(ctx, cr.number)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      refute has_element?(view, "#review-panel")
      assert has_element?(view, "#evidence-panel", "Last computed evidence")
      assert has_element?(view, "#evidence-frozen", "closed")
      assert has_element?(view, "#evidence-panel", "Review count")
      assert has_element?(view, "#evidence-review-count", "0 of 1 cleared")
    end

    test "an active change request shows the review count only in Review items", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#review-cleared", "0 of 1 cleared")
      refute has_element?(view, "#evidence-review-count")
    end

    test "the history lists the opening, then draft to open with who made it", ctx do
      cr = create!(ctx)
      ready!(ctx, cr.number)
      email = Repo.preload(ctx.sk_key, account_user: :user).account_user.user.email

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#history-panel #history-opened", "Opened as draft by #{email}")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#history-panel li")
        |> LazyHTML.attribute("id")

      assert ["history-opened", "history-" <> _ = moved] = ids
      assert has_element?(view, "##{moved}", "Draft")
      assert has_element?(view, "##{moved}", "Open")
      assert has_element?(view, "##{moved}", "by #{email}")
    end

    test "a missing required workflow shows as missing", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"evidence" => %{"required_workflows" => ["ci"]}})
      cr = create!(ctx)
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number})

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#evidence-panel", "Evidence at head")
      assert has_element?(view, "#workflow-ci", "missing")
      assert has_element?(view, "#claims-summary", "Two-way door")
    end

    test "a diff scenario set shows whether it is accepted", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "scenarios" => %{
          "require_approved_intent" => true,
          "diff_only" => "weakening",
          "approver" => "any"
        }
      })

      cr = create!(ctx)
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number})

      [_d1, d2] =
        for scenarios <- [
              [scenario("S1"), scenario("S3")],
              [scenario("S1"), scenario("S3", "should")]
            ] do
          ctx.sk_conn
          |> post_json(
            cr_path(ctx.slug, cr.number, "/scenario-sets"),
            set_body(diff_fm(sha(1), scenarios))
          )
          |> json_response(201)
          |> get_in(["data", "digest"])
        end

      doc = run_doc(d2, "diff", sha(1), [result("S1"), result("S3")])

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{ctx.slug}/verify-runs", doc)
        |> json_response(201)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#scenario-set-diff", "Version 2")
      assert has_element?(view, "#scenario-set-diff", "not accepted")

      weakened = item!(packet(ctx.sk_conn, ctx.slug, cr.number), "diff_set_weakened")
      body = %{"head" => sha(1), "answer" => "approve"}
      _ = ctx.sk_conn |> answer(ctx.slug, cr.number, weakened["id"], body) |> json_response(201)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#scenario-set-diff", "Version 2")
      refute has_element?(view, "#scenario-set-diff", "not accepted")
      assert has_element?(view, "#scenario-set-diff", "accepted")
    end

    test "a held lease names its key and expiry; without one, No lease held", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, number))
      assert has_element?(view, "#no-lease", "No lease held")

      lease = acquire!(ctx.sk_conn, ctx.slug, number, sha(1), sha(0))
      {:ok, expires_at, 0} = DateTime.from_iso8601(lease["expires_at"])
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, number))
      assert has_element?(view, "#lease-held", ctx.sk_key.name)

      assert has_element?(
               view,
               "#lease-held",
               Calendar.strftime(expires_at, "%Y-%m-%d %H:%M UTC")
             )

      Repo.delete_all(Verdict)
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, number))
      assert has_element?(view, "#lease-held", ctx.sk_key.name)
    end
  end

  describe "live refresh" do
    defp graded!(ctx, door) do
      cr = create!(ctx, %{"change_id" => "add-export"})
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number, "door" => door})

      digest =
        ctx.sk_conn
        |> post_json(
          cr_path(ctx.slug, cr.number, "/scenario-sets"),
          set_body(intent_fm("add-export"))
        )
        |> json_response(201)
        |> get_in(["data", "digest"])

      _ =
        ctx.sk_conn
        |> post_json(cr_path(ctx.slug, cr.number, "/scenario-sets/intent/approvals"), %{
          "digest" => digest
        })
        |> json_response(201)

      run!(ctx, digest, [result("S1"), result("S2", "not_run")], "2026-11-20T10:00:00Z")
      {cr, digest}
    end

    defp run!(ctx, digest, results, finished_at) do
      doc = run_doc(digest, "intent", sha(1), results, finished_at: finished_at)

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{ctx.slug}/verify-runs", doc)
        |> json_response(201)
    end

    test "a verify run that changes the verdict", ctx do
      {cr, digest} = graded!(ctx, "two_way")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#header-verdict", "Needs review")

      run!(ctx, digest, [result("S1"), result("S2")], "2026-11-20T11:00:00Z")
      _ = project_event(view, ctx)
      assert has_element?(view, "#header-verdict", "Mergeable")
    end

    test "a verify run that changes the reasons but not the state", ctx do
      {cr, digest} = graded!(ctx, "one_way")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#reasons", "should_not_run")

      run!(ctx, digest, [result("S1"), result("S2")], "2026-11-20T11:00:00Z")
      _ = project_event(view, ctx)
      assert has_element?(view, "#header-verdict", "Needs review")
      assert has_element?(view, "#reasons", "one_way_door")
      refute has_element?(view, "#reasons", "should_not_run")
    end

    test "a retarget", ctx do
      cr = create!(ctx)
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      _ = ctx.sk_conn |> retarget(ctx.slug, cr.number, "release/2") |> json_response(200)
      _ = project_event(view, ctx)
      assert has_element?(view, "#target-branch", "release/2")
    end

    test "a completed task", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      door = item!(packet(ctx.sk_conn, ctx.slug, cr.number), "one_way_door")
      body = %{"head" => sha(1), "answer" => "request_change", "note" => "split it"}
      _ = ctx.sk_conn |> answer(ctx.slug, cr.number, door["id"], body) |> json_response(201)

      [task] =
        ctx.sk_conn
        |> get(cr_path(ctx.slug, cr.number, "/tasks"))
        |> json_response(200)
        |> Map.fetch!("data")

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#task-#{task["id"]}", "split it")

      _ =
        ctx.sk_conn
        |> post(cr_path(ctx.slug, cr.number, "/tasks/#{task["id"]}/done"))
        |> json_response(200)

      _ = project_event(view, ctx)
      refute has_element?(view, "#task-#{task["id"]}")
    end
  end

  describe "answers" do
    test "approve stores the member's answer at the head the page showed", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      door_id = item_id(ctx, cr.number, "one_way_door")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#review-cleared", "0 of 1 cleared")

      view |> element("##{door_id}-approve") |> render_click()
      assert has_element?(view, "#answer-dialog #answer-confirm", "Approve")

      _ = project_event(view, ctx)
      assert has_element?(view, "#answer-dialog")

      view |> form("#answer-form", answer: %{note: ""}) |> render_submit()

      refute has_element?(view, "#answer-dialog")
      assert has_element?(view, "##{door_id}-answer", "Approved by #{ctx.user.email}")
      assert has_element?(view, "#review-cleared", "1 of 1 cleared")
      assert has_element?(view, "#header-verdict", "Mergeable")

      assert [%Answer{answer: "approve", channel: "dashboard", api_key_id: nil} = stored] =
               Repo.all(Answer)

      assert stored.account_user_id == ctx.membership.id
      assert stored.head == sha(1)
    end

    test "choose drop stores choose with option drop", ctx do
      cr = create!(ctx)

      one_way!(ctx, cr.number, sha(1), %{
        "door" => "two_way",
        "questions" => [
          %{
            "id" => "q1",
            "text" => "Keep it?",
            "options" => ["keep", "drop"],
            "recommendation" => "keep"
          }
        ]
      })

      question_id = item_id(ctx, cr.number, "question")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      view |> element("##{question_id}-choose") |> render_click()
      view |> form("#answer-form", answer: %{option: "drop", note: ""}) |> render_submit()

      assert [%Answer{answer: "choose", option: "drop", channel: "dashboard"}] = Repo.all(Answer)
      assert has_element?(view, "##{question_id}-answer", "Chose drop")
    end

    test "request change with an empty note shows the field error and stores nothing", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      door_id = item_id(ctx, cr.number, "one_way_door")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      view |> element("##{door_id}-request_change") |> render_click()
      assert has_element?(view, "#answer-confirm", "Request change")
      view |> form("#answer-form", answer: %{note: ""}) |> render_submit()

      assert has_element?(view, "#answer-dialog #answer_note-error-0", "Write a note")
      assert Repo.aggregate(Answer, :count) == 0
    end

    test "a new head between opening the dialog and confirming stores nothing", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      door_id = item_id(ctx, cr.number, "one_way_door")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      view |> element("##{door_id}-approve") |> render_click()
      one_way!(ctx, cr.number, sha(2))
      view |> form("#answer-form", answer: %{note: ""}) |> render_submit()

      assert Repo.aggregate(Answer, :count) == 0
      assert render(view) =~ "A new head was reported. Review the items at the new head."
      refute has_element?(view, "#answer-dialog")
      assert has_element?(view, "#details-panel", String.slice(sha(2), 0, 7))
      assert has_element?(view, "##{door_id}-unanswered")
    end

    test "the author under other_member sees no actions on the set approval", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "scenarios" => %{"require_approved_intent" => true, "approver" => "other_member"}
      })

      {_key, token} = api_key_fixture(ctx.membership, %{type: :private})
      author = api_conn(token)
      number = create_cr(author, ctx.slug, %{"change_id" => "add-export"})["number"]

      _ =
        author
        |> post_json(
          cr_path(ctx.slug, number, "/scenario-sets"),
          set_body(intent_fm("add-export"))
        )
        |> json_response(201)

      set_id = item_id(ctx, number, "scenario_set_approval")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, number))

      assert has_element?(view, "##{set_id}")
      refute has_element?(view, "##{set_id}-approve")
      assert has_element?(view, "##{set_id}-who", "Another member must approve this set")
    end

    test "a plain member under admin sees no actions on the set approval", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "scenarios" => %{"require_approved_intent" => true, "approver" => "admin"}
      })

      number = create_cr(ctx.sk_conn, ctx.slug, %{"change_id" => "add-export"})["number"]

      _ =
        ctx.sk_conn
        |> post_json(
          cr_path(ctx.slug, number, "/scenario-sets"),
          set_body(intent_fm("add-export"))
        )
        |> json_response(201)

      set_id = item_id(ctx, number, "scenario_set_approval")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, number))

      refute has_element?(view, "##{set_id}-approve")
      refute has_element?(view, "##{set_id}-reject")
      assert has_element?(view, "##{set_id}-who", "An owner or admin must approve this set")

      render_click(view, "open_answer", %{
        "item" => item!(packet(ctx.sk_conn, ctx.slug, number), "scenario_set_approval")["id"],
        "answer" => "approve"
      })

      refute has_element?(view, "#answer-dialog")
      assert Repo.aggregate(Answer, :count) == 0
    end

    test "a policy change to admin between opening the dialog and confirming is refused", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "scenarios" => %{"require_approved_intent" => true, "approver" => "any"}
      })

      number = create_cr(ctx.sk_conn, ctx.slug, %{"change_id" => "add-export"})["number"]

      _ =
        ctx.sk_conn
        |> post_json(
          cr_path(ctx.slug, number, "/scenario-sets"),
          set_body(intent_fm("add-export"))
        )
        |> json_response(201)

      set_id = item_id(ctx, number, "scenario_set_approval")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, number))
      view |> element("##{set_id}-approve") |> render_click()

      policy!(
        ctx.sk_conn,
        ctx.slug,
        %{"scenarios" => %{"require_approved_intent" => true, "approver" => "admin"}},
        1
      )

      view |> form("#answer-form", answer: %{note: ""}) |> render_submit()

      assert render(view) =~ "You can&#39;t answer this item"
      refute has_element?(view, "#answer-dialog")
      assert has_element?(view, "##{set_id}-who", "An owner or admin must approve this set")
      assert Repo.aggregate(Answer, :count) == 0
    end

    test "a close between opening the dialog and confirming stores nothing", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      door_id = item_id(ctx, cr.number, "one_way_door")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      view |> element("##{door_id}-approve") |> render_click()
      close!(ctx, cr.number)
      view |> form("#answer-form", answer: %{note: ""}) |> render_submit()

      assert render(view) =~ "This change request is no longer open"
      refute has_element?(view, "#answer-dialog")
      refute has_element?(view, "#review-panel")
      assert Repo.aggregate(Answer, :count) == 0
    end

    test "an item gone at the same head gets its own flash and stores nothing", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "paths" => [%{"glob" => "priv/**", "outcome" => "needs_review"}]
      })

      cr = create!(ctx)
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1), files: [file("priv/a.sql")])
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number})
      path_id = item_id(ctx, cr.number, "sensitive_path")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      view |> element("##{path_id}-approve") |> render_click()
      policy!(ctx.sk_conn, ctx.slug, %{"paths" => []}, 1)
      view |> form("#answer-form", answer: %{note: ""}) |> render_submit()

      html = render(view)
      assert html =~ "This item no longer needs an answer at this head."
      refute html =~ "A new head was reported"
      refute has_element?(view, "#answer-dialog")
      refute has_element?(view, "##{path_id}")
      assert has_element?(view, "#details-panel", String.slice(sha(1), 0, 7))
      assert Repo.aggregate(Answer, :count) == 0
    end
  end

  describe "evidence panels" do
    defp head!(ctx, attrs \\ %{}) do
      cr = create!(ctx, attrs)
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number})
      cr
    end

    defp set!(ctx, number, body) do
      ctx.sk_conn
      |> post_json(cr_path(ctx.slug, number, "/scenario-sets"), body)
      |> json_response(201)
      |> get_in(["data", "digest"])
    end

    defp approve_set!(ctx, number, digest) do
      ctx.sk_conn
      |> post_json(cr_path(ctx.slug, number, "/scenario-sets/intent/approvals"), %{
        "digest" => digest
      })
      |> json_response(201)
    end

    defp verify!(ctx, digest, source, results, opts \\ []) do
      doc = run_doc(digest, source, sha(1), results, opts)

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{ctx.slug}/verify-runs", doc)
        |> json_response(201)

      doc["run_id"]
    end

    defp workflow!(ctx, workflow, outcome, started_at, extra \\ %{}, opts \\ []) do
      doc =
        sha(1)
        |> run_document(outcome, [workflow: workflow, started_at: started_at] ++ opts)
        |> Map.merge(extra)

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{ctx.slug}/workflow-runs", doc)
        |> json_response(201)

      doc["run_id"]
    end

    defp short_id(id), do: String.slice(id, 0, 7)

    test "graded sets show status, revision, baseline, the run and each result", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "scenarios" => %{"require_approved_intent" => true, "approver" => "any"}
      })

      cr = head!(ctx, %{"change_id" => "add-export"})
      intent = set!(ctx, cr.number, set_body(intent_fm("add-export", [scenario("S1")])))
      approve_set!(ctx, cr.number, intent)

      diff =
        set!(
          ctx,
          cr.number,
          set_body(diff_fm(sha(1), [scenario("retry-backoff"), scenario("D2", "should")]))
        )

      intent_run = verify!(ctx, intent, "intent", [result("S1")])
      diff_run = verify!(ctx, diff, "diff", [result("retry-backoff", "failed"), result("D2")])

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#qa-set-intent-status", "Approved")
      refute has_element?(view, "#qa-set-intent-not-graded")
      assert has_element?(view, "#qa-set-intent-version", "v1")
      assert has_element?(view, "#qa-set-intent-run", short_id(intent_run))
      assert has_element?(view, "#qa-set-intent-uploaded", "Key #{ctx.sk_key.name}")
      assert has_element?(view, "#qa-set-diff-status", "Not accepted")
      assert has_element?(view, "#qa-set-diff-revision", "Names the head")
      assert has_element?(view, "#qa-set-diff-revision", "baseline v1")
      assert has_element?(view, "#qa-set-diff-run", short_id(diff_run))
      assert has_element?(view, "#qa-set-diff", "Must 0/1")
      assert has_element?(view, "#scenario-diff-retry-backoff", "Scenario retry-backoff")
      assert has_element?(view, "#scenario-diff-retry-backoff", "Must")
      assert has_element?(view, "#scenario-diff-retry-backoff", "Failed")
      assert has_element?(view, "#scenario-diff-D2", "Passed")
      assert has_element?(view, "#qa-set-diff-decisions", "No decisions on this version.")

      for run_id <- [intent_run, diff_run] do
        assert has_element?(view, "#verify-run-#{run_id} [data-mark=counts]", "Counts")
      end
    end

    test "an unapproved intent set is not graded and lists a dashboard rejection", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"scenarios" => %{"require_approved_intent" => true}})
      cr = head!(ctx, %{"change_id" => "add-export"})
      digest = set!(ctx, cr.number, set_body(intent_fm("add-export", [scenario("S1")])))
      run_id = verify!(ctx, digest, "intent", [result("S1")])

      {:ok, {:created, _decision}} =
        Repo.transaction(fn ->
          ScenarioSets.record_decision(
            ChangeRequests.lock_active(cr),
            Review.dashboard_actor(ctx.membership),
            %{decision: "reject", digest: digest, note: "Check Retry-After"}
          )
        end)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#qa-set-intent-status", "Not approved")
      assert has_element?(view, "#qa-set-intent-not-graded", "Not graded")
      assert has_element?(view, "#qa-set-intent-not-graded-note", "approved")
      assert has_element?(view, "#scenario-intent-S1", "No result")
      assert has_element?(view, "#qa-set-intent-run", "No counted run")
      assert has_element?(view, "#verify-run-#{run_id}", "Intent set not approved")

      decisions = "#qa-set-intent-decisions"
      assert has_element?(view, decisions, "Rejected by #{ctx.user.email}")
      assert has_element?(view, decisions, "dashboard")
      assert has_element?(view, decisions, "Check Retry-After")
    end

    test "a member approves the intent set version shown, and a new version asks again", ctx do
      cr = head!(ctx, %{"change_id" => "add-export"})
      v1 = set!(ctx, cr.number, set_body(intent_fm("add-export", [scenario("S1")])))
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#qa-set-intent-decide-trigger", "Decide on v1")
      assert has_element?(view, "#qa-set-intent-decide", "1 must scenario")
      assert has_element?(view, "#qa-set-intent-decide", short_id(v1))

      view
      |> form("#qa-set-intent-decision-form")
      |> render_submit(%{"answer" => "approve"})

      assert has_element?(view, "#qa-set-intent-status", "Approved")
      refute has_element?(view, "#qa-set-intent-decide")
      assert has_element?(view, "#qa-set-intent-decisions", "Approved by #{ctx.user.email}")
      assert has_element?(view, "#qa-set-intent-decisions", "dashboard")
      assert [%{decision: "approve", channel: "dashboard"}] = ScenarioSets.decisions(cr, v1)

      _v2 =
        set!(ctx, cr.number, set_body(intent_fm("add-export", [scenario("S1"), scenario("S2")])))

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#qa-set-intent-status", "Not approved")
      assert has_element?(view, "#qa-set-intent-approve", "Approve v2")
    end

    test "rejecting needs a note, and a set replaced while open is not decided", ctx do
      cr = head!(ctx, %{"change_id" => "add-export"})
      v1 = set!(ctx, cr.number, set_body(intent_fm("add-export", [scenario("S1")])))
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      view
      |> form("#qa-set-intent-decision-form", %{"set_decision" => %{"note" => " "}})
      |> render_submit(%{"answer" => "reject"})

      assert has_element?(view, "#qa-set-intent-decide", "Write a note")
      assert ScenarioSets.decisions(cr, v1) == []

      _v2 = set!(ctx, cr.number, set_body(intent_fm("add-export", [scenario("S2")])))

      # The popover still holds v1's digest, as a page that hasn't reloaded yet would.
      render_submit(view, "decide_set", %{
        "answer" => "reject",
        "digest" => v1,
        "set_decision" => %{"note" => "Too thin"}
      })

      assert has_element?(view, "#flash-error", "The scenario set changed")
      assert ScenarioSets.decisions(cr, v1) == []
      assert has_element?(view, "#qa-set-intent-approve", "Approve v2")
    end

    test "a member the approver rule excludes sees who may approve instead", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"scenarios" => %{"approver" => "other_member"}})
      {_key, token} = api_key_fixture(ctx.membership, %{type: :private})
      author = api_conn(token)
      number = create_cr(author, ctx.slug, %{"change_id" => "add-export"})["number"]

      _ =
        author
        |> post_json(
          cr_path(ctx.slug, number, "/scenario-sets"),
          set_body(intent_fm("add-export"))
        )
        |> json_response(201)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, number))

      refute has_element?(view, "#qa-set-intent-decide")
      assert has_element?(view, "#qa-set-intent-who", "Another member must approve this set")
    end

    test "a graded intent set with only a dirty run shows No result", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "scenarios" => %{"require_approved_intent" => true, "approver" => "any"}
      })

      cr = head!(ctx, %{"change_id" => "add-export"})
      digest = set!(ctx, cr.number, set_body(intent_fm("add-export", [scenario("S1")])))
      approve_set!(ctx, cr.number, digest)
      dirty = verify!(ctx, digest, "intent", [result("S1")], dirty: true)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#qa-set-intent-status", "Approved")
      refute has_element?(view, "#qa-set-intent-not-graded")
      assert has_element?(view, "#scenario-intent-S1", "No result")
      assert has_element?(view, "#qa-set-intent-run", "No counted run")
      assert has_element?(view, "#verify-run-#{dirty}", "Dirty tree")
    end

    test "verify runs: Counts, Dirty tree and Older set version, newest first", ctx do
      cr = head!(ctx, %{"change_id" => "add-export"})
      fm = intent_fm("add-export", [scenario("S1")])
      v1 = set!(ctx, cr.number, set_body(fm))
      older = verify!(ctx, v1, "intent", [result("S1")], finished_at: "2026-11-20T09:00:00Z")
      v2 = set!(ctx, cr.number, set_body(fm, body: "edited\n"))
      counted = verify!(ctx, v2, "intent", [result("S1")], finished_at: "2026-11-20T10:00:00Z")

      dirty =
        verify!(ctx, v2, "intent", [result("S1", "failed")],
          finished_at: "2026-11-20T11:00:00Z",
          dirty: true
        )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#verify-run-#{counted} [data-mark=counts]", "Counts")
      assert has_element?(view, "#verify-run-#{dirty}", "Dirty tree")
      assert has_element?(view, "#verify-run-#{dirty}", "0 passed · 1 failed · 0 not run")
      assert has_element?(view, "#verify-run-#{older}", "Older set version")
      assert has_element?(view, "#verify-run-#{older}", "Intent v1")
      assert has_element?(view, "#verify-run-#{counted}", "Intent v2")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#verify-runs tr")
        |> LazyHTML.attribute("id")

      assert ids == Enum.map([dirty, counted, older], &"verify-run-#{&1}")
    end

    test "workflow runs: required, missing and other rows, and the CI link", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "evidence" => %{"required_workflows" => ["ci", "e2e", "lint"]}
      })

      cr = head!(ctx)
      url = "https://github.com/acme/web/actions/runs/1"
      ci = %{"provider" => "github_actions", "event" => "push", "attempt" => 2, "url" => url}
      _failed = workflow!(ctx, "ci", "failed", "2026-11-05T10:00:00Z")
      passed = workflow!(ctx, "ci", "passed", "2026-11-05T11:00:00Z", %{"ci" => ci})
      _dirty = workflow!(ctx, "ci", "failed", "2026-11-05T12:00:00Z", %{}, dirty: true)
      _lint = workflow!(ctx, "lint", "passed", "2026-11-05T10:00:00Z")

      _perf =
        workflow!(ctx, "nightly-perf", "passed", "2026-11-05T10:00:00Z", %{
          "ci" => %{"provider" => "github_actions", "event" => "schedule"}
        })

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#workflow-runs tr")
        |> LazyHTML.attribute("id")

      assert ids ==
               ~w(workflow-run-ci workflow-run-e2e workflow-run-lint workflow-run-nightly-perf)

      assert has_element?(view, "#workflow-run-ci", "Required")
      assert has_element?(view, "#workflow-run-ci", "Passed")
      assert has_element?(view, "#workflow-run-ci", "push · attempt 2")
      assert has_element?(view, ~s(#workflow-run-ci-ci[href="#{url}"]))
      assert has_element?(view, "#workflow-run-e2e", "Required")
      assert has_element?(view, "#workflow-run-e2e", "Missing")
      assert has_element?(view, "#workflow-run-e2e-missing", "No clean run of this workflow")
      refute has_element?(view, "#workflow-run-e2e", "None")
      assert has_element?(view, "#workflow-runs-summary", "2 of 3 required passed")
      assert has_element?(view, "#workflow-runs-summary", String.slice(sha(1), 0, 7))
      assert has_element?(view, "#workflow-run-lint", "Local run")
      assert has_element?(view, "#workflow-run-nightly-perf", "Not required")
      assert has_element?(view, "#workflow-run-nightly-perf", "No CI link")
      assert passed in (ChangeRequests.verdict(cr).inputs["required_workflows"] |> Map.values())
    end

    test "a merged change request shows frozen panels with Counts and Not counted", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"evidence" => %{"required_workflows" => ["ci"]}})
      cr = head!(ctx)
      diff = set!(ctx, cr.number, set_body(diff_fm(sha(1), [scenario("D1")])))
      counted = verify!(ctx, diff, "diff", [result("D1")], finished_at: "2026-11-20T10:00:00Z")

      dirty =
        verify!(ctx, diff, "diff", [result("D1")],
          finished_at: "2026-11-20T11:00:00Z",
          dirty: true
        )

      _ci = workflow!(ctx, "ci", "passed", "2026-11-05T10:00:00Z")
      merge!(ctx, cr.number)

      late = verify!(ctx, diff, "diff", [result("D1")], finished_at: "2026-11-20T12:00:00Z")
      _perf = workflow!(ctx, "nightly-perf", "passed", "2026-11-05T11:00:00Z")

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      refute has_element?(view, "#verify-run-#{late}")
      refute has_element?(view, "#workflow-run-nightly-perf")

      assert has_element?(view, "#qa-frozen", "Nothing updates it now")
      assert has_element?(view, "#workflow-runs-frozen", "Nothing updates them now")
      assert has_element?(view, "#qa-set-diff-version", "v1")
      assert has_element?(view, "#scenario-diff-D1", "Passed")
      assert has_element?(view, "#verify-run-#{counted} [data-mark=counts]", "Counts")
      assert has_element?(view, "#verify-run-#{dirty} [data-mark=not_counted]", "Not counted")
      refute has_element?(view, "#verify-runs", "Dirty tree")
      assert has_element?(view, "#workflow-run-ci", "Passed")
    end

    test "a frozen panel keeps its runs after more than 50 later runs on its digest", ctx do
      cr = head!(ctx)
      diff = set!(ctx, cr.number, set_body(diff_fm(sha(1), [scenario("D1")])))
      counted = verify!(ctx, diff, "diff", [result("D1")], finished_at: "2026-11-20T10:00:00Z")
      merge!(ctx, cr.number)

      for i <- 1..51 do
        second = String.pad_leading("#{i}", 2, "0")
        _ = verify!(ctx, diff, "diff", [result("D1")], finished_at: "2026-11-21T10:00:#{second}Z")
      end

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#verify-run-#{counted} [data-mark=counts]", "Counts")
      refute has_element?(view, "#no-verify-runs")
      assert has_element?(view, "#qa-set-diff-run", "Finished")
    end

    test "a closed change request shows frozen panels with Counts and Not counted", ctx do
      cr = head!(ctx)
      diff = set!(ctx, cr.number, set_body(diff_fm(sha(1), [scenario("D1")])))
      counted = verify!(ctx, diff, "diff", [result("D1")], finished_at: "2026-11-20T10:00:00Z")

      dirty =
        verify!(ctx, diff, "diff", [result("D1")],
          finished_at: "2026-11-20T11:00:00Z",
          dirty: true
        )

      _smoke = workflow!(ctx, "smoke", "passed", "2026-11-05T10:00:00Z")
      close!(ctx, cr.number)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      assert has_element?(view, "#qa-frozen", "closed")
      assert has_element?(view, "#workflow-runs-frozen")
      assert has_element?(view, "#scenario-diff-D1", "Passed")
      assert has_element?(view, "#verify-run-#{counted} [data-mark=counts]", "Counts")
      assert has_element?(view, "#verify-run-#{dirty} [data-mark=not_counted]", "Not counted")
      refute has_element?(view, "#verify-runs", "Dirty tree")
      assert has_element?(view, "#workflow-run-smoke", "Not required")
    end

    test "a non-required workflow run and a dirty verify run appear without a reload", ctx do
      cr = head!(ctx)
      diff = set!(ctx, cr.number, set_body(diff_fm(sha(1), [scenario("D1")])))
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#no-workflow-runs")
      assert has_element?(view, "#no-verify-runs")

      _perf = workflow!(ctx, "nightly-perf", "passed", "2026-11-05T10:00:00Z")
      _ = project_event(view, ctx)
      assert has_element?(view, "#workflow-run-nightly-perf", "Not required")

      dirty = verify!(ctx, diff, "diff", [result("D1")], dirty: true)
      _ = project_event(view, ctx)
      assert has_element?(view, "#verify-run-#{dirty}", "Dirty tree")
    end
  end

  describe "scenario details" do
    defp set_body_with_cli_digests(fm, texts \\ %{}) do
      pieces =
        for s <- fm["scenarios"] do
          id = to_string(s["id"])
          {id, "### #{id}. #{s["name"]} (Must)\n\n#{Map.get(texts, id, "Why: #{id}.")}\n\n"}
        end

      body = "# QA\n\n## Scenarios\n\n" <> Enum.map_join(pieces, "", &elem(&1, 1))

      sections =
        for {id, piece} <- pieces,
            do: %{
              "id" => id,
              "sha256" => :sha256 |> :crypto.hash(piece) |> Base.encode16(case: :lower)
            }

      %{"content" => set_content(fm, body), "sections" => sections}
    end

    defp upload_set!(ctx, number, body) do
      ctx.sk_conn
      |> post_json(cr_path(ctx.slug, number, "/scenario-sets"), body)
      |> json_response(201)
      |> get_in(["data", "digest"])
    end

    defp head_cr!(ctx, attrs \\ %{}) do
      cr = create!(ctx, attrs)
      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number})
      cr
    end

    defp final_run!(ctx, digest, source, results, artifacts \\ []) do
      doc = run_doc(digest, source, sha(1), results, artifacts: Enum.map(artifacts, &elem(&1, 0)))

      {:ok, %{run: run, uploads: uploads}} =
        GoodFlows.VerifyRuns.ingest(ctx.account, ctx.project, ctx.sk_key, doc)

      for {upload, {_declared, bytes}} <- Enum.zip(uploads, artifacts),
          do: :ok = Fake.put(upload.upload_url, upload.upload_headers, bytes)

      if artifacts != [],
        do: {:ok, _final} = GoodFlows.VerifyRuns.commit(ctx.project, ctx.sk_key, run.run_id)

      run
    end

    defp toggle(view, source, id),
      do: view |> element("#scenario-#{source}-#{id}-toggle") |> render_click()

    @steps """
    Why: an update that wipes the fields it was not sent would lose the title.

    1. Send `PATCH /todos/1` with `{"done":true}`.
       - Expect: status `200`.
    2. Click **Save** and enter `-1` in **Quantity**.
       - Expect: the title is kept.
    3. Send `GET /todos/1`.
       - Expect: body `{"id":1,"title":"buy milk","done":true}`.
    4. Reload the list page.
       - Expect: the todo shows as done with its title.
    """

    test "a row opens and closes, aria-expanded follows, and it stays open after a refresh",
         ctx do
      cr = head_cr!(ctx)
      fm = diff_fm(sha(1), [scenario(2), scenario(3)])
      _digest = upload_set!(ctx, cr.number, set_body_with_cli_digests(fm, %{"2" => @steps}))

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      toggle_2 = "#scenario-diff-2-toggle"

      refute has_element?(view, "#scenario-diff-2-details")
      assert has_element?(view, "#{toggle_2}[aria-expanded=false]", "Show details for 2")
      refute has_element?(view, "#{toggle_2}[aria-controls]")

      toggle(view, "diff", 2)
      assert has_element?(view, "#scenario-diff-2 + #scenario-diff-2-details")
      assert has_element?(view, "#{toggle_2}[aria-expanded=true]", "Hide details for 2")
      assert has_element?(view, "#{toggle_2}[aria-controls=scenario-diff-2-details]")
      refute has_element?(view, "#scenario-diff-3-details")

      _ = project_event(view, ctx)
      assert has_element?(view, "#scenario-diff-2-details")
      assert has_element?(view, "#{toggle_2}[aria-expanded=true]")

      toggle(view, "diff", 2)
      refute has_element?(view, "#scenario-diff-2-details")
      assert has_element?(view, "#{toggle_2}[aria-expanded=false]")
      refute has_element?(view, "#{toggle_2}[aria-controls]")

      render_click(view, "toggle_scenario", %{"source" => "diff", "id" => "nope"})
      refute has_element?(view, ".data-table-details")
    end

    test "a matched section shows its Why and steps rendered, without the heading", ctx do
      cr = head_cr!(ctx)
      fm = diff_fm(sha(1), [scenario(2)])
      _digest = upload_set!(ctx, cr.number, set_body_with_cli_digests(fm, %{"2" => @steps}))

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      toggle(view, "diff", 2)

      text = "#scenario-diff-2-text.scenario-markdown"
      assert has_element?(view, "#{text} > p", "Why: an update that wipes")
      assert has_element?(view, "#{text} > ol > li > ul > li", "Expect: status 200.")
      assert has_element?(view, "#{text} > ol > li:nth-child(2) > ul > li", "the title is kept")
      assert has_element?(view, "#{text} > ol > li:nth-child(4) > ul > li", "shows as done")
      refute has_element?(view, "#{text} > ol > li:nth-child(5)")
      assert has_element?(view, "#{text} strong", "Save")
      assert has_element?(view, "#{text} strong", "Quantity")
      assert has_element?(view, "#{text} code", "-1")
      refute has_element?(view, text, "Scenario 2")
      refute has_element?(view, "#{text} h3")
      refute has_element?(view, "#scenario-diff-2-unmatched")
    end

    test "raw HTML in a section renders no script element and no handler", ctx do
      cr = head_cr!(ctx)
      fm = diff_fm(sha(1), [scenario(2)])

      raw = """
      <script>alert(1)</script>

      Look <img src=x onerror=alert(1)> here and [docs](javascript:alert(1)).
      """

      _digest = upload_set!(ctx, cr.number, set_body_with_cli_digests(fm, %{"2" => raw}))

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      html = toggle(view, "diff", 2)

      assert has_element?(view, "#scenario-diff-2-text", "here and")
      refute has_element?(view, "#scenario-diff-2-details script")
      refute has_element?(view, "#scenario-diff-2-details [onerror]")
      refute has_element?(view, "#scenario-diff-2-details img")
      refute html =~ "javascript:"
    end

    test "a version whose digest does not match shows the unmatched note and no text", ctx do
      cr = head_cr!(ctx)
      fm = diff_fm(sha(1), [scenario("S1"), scenario("S2")])
      body = set_body_with_cli_digests(fm, %{"S2" => @steps})

      sections =
        for %{"id" => "S2"} = s <- body["sections"], do: %{s | "sha256" => section_sha("S2")}

      body = %{body | "sections" => [hd(body["sections"]) | sections]}
      _digest = upload_set!(ctx, cr.number, body)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      toggle(view, "diff", "S1")
      toggle(view, "diff", "S2")

      assert has_element?(view, "#scenario-diff-S1-text", "Why: S1.")

      assert has_element?(
               view,
               "#scenario-diff-S2-unmatched",
               "could not be matched to the set file"
             )

      refute has_element?(view, "#scenario-diff-S2-text")
      refute has_element?(view, "#scenario-diff-S2-details", "Why: an update")
    end

    test "a failed must shows its step, reason and evidence; an expired artifact has no link",
         ctx do
      cr = head_cr!(ctx)
      fm = diff_fm(sha(1), [scenario("retry-backoff"), scenario("D2", "should")])
      digest = upload_set!(ctx, cr.number, set_body_with_cli_digests(fm))

      shot = :crypto.strong_rand_bytes(120_000)
      log = "log bytes"

      failed =
        "retry-backoff"
        |> result("failed", ["shot-3", "log-1"])
        |> Map.merge(%{"failed_step" => "3", "reason" => ~s(Banner read "Saved")})

      run =
        final_run!(ctx, digest, "diff", [failed, result("D2", "not_run")], [
          {artifact("shot-3", shot), shot},
          {artifact("log-1", log, "text/plain"), log}
        ])

      Repo.update_all(
        from(a in GoodFlows.VerifyRuns.Artifact,
          where: a.verify_run_id == ^run.id and a.artifact_id == "log-1"
        ),
        set: [expired: true]
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      toggle(view, "diff", "retry-backoff")
      html = toggle(view, "diff", "D2")

      dom = "#scenario-diff-retry-backoff"
      assert has_element?(view, "#{dom}-failed-step", "Failed at 3")
      assert has_element?(view, "#{dom}-reason", ~s(Banner read "Saved"))

      href =
        "/dashboard/accounts/#{ctx.account.id}/projects/#{ctx.slug}/verify-runs/#{run.run_id}/artifacts/shot-3"

      shot_item = "#{dom}-gallery > li#{dom}-evidence-shot-3"
      assert has_element?(view, "#{shot_item} img[src='#{href}']")

      assert has_element?(
               view,
               "#{shot_item} a#scenario-diff-retry-backoff-evidence-shot-3-download[href='#{href}'][aria-label='Download shots/shot-3.png']"
             )

      assert has_element?(
               view,
               "#{shot_item} .evidence-caption[title='shots/shot-3.png']",
               "shot-3.png"
             )

      refute render(view) =~ "image/png"
      refute render(view) =~ "KiB"

      log_item = "#{dom}-evidence > li#{dom}-evidence-log-1"
      assert has_element?(view, log_item, "Expired")
      refute has_element?(view, "#{log_item} a")

      assert has_element?(view, "#scenario-diff-D2-reason", "it broke")
      refute has_element?(view, "#scenario-diff-D2-failed-step")
      refute html =~ "X-Amz-Signature"
    end

    test "image evidence shows as thumbnails that open a lightbox stepping through them", ctx do
      cr = head_cr!(ctx)
      fm = diff_fm(sha(1), [scenario("retry-backoff")])
      digest = upload_set!(ctx, cr.number, set_body_with_cli_digests(fm))

      [before, after_, expired_shot, log] = ["before", "after", "gone", "log"]

      failed = result("retry-backoff", "failed", ["shot-1", "log-1", "shot-2", "shot-3"])

      run =
        final_run!(ctx, digest, "diff", [failed], [
          {artifact("shot-1", before), before},
          {artifact("log-1", log, "text/plain"), log},
          {artifact("shot-2", after_), after_},
          {artifact("shot-3", expired_shot), expired_shot}
        ])

      Repo.update_all(
        from(a in GoodFlows.VerifyRuns.Artifact,
          where: a.verify_run_id == ^run.id and a.artifact_id == "shot-3"
        ),
        set: [expired: true]
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      toggle(view, "diff", "retry-backoff")

      dom = "#scenario-diff-retry-backoff"

      path =
        &"/dashboard/accounts/#{ctx.account.id}/projects/#{ctx.slug}/verify-runs/#{run.run_id}/artifacts/#{&1}"

      assert has_element?(
               view,
               "#{dom}-gallery li:nth-child(1) img[src='#{path.("shot-1")}']"
             )

      assert has_element?(
               view,
               "#{dom}-gallery li:nth-child(2) img[src='#{path.("shot-2")}']"
             )

      refute has_element?(view, "#{dom}-gallery li:nth-child(3)")
      refute has_element?(view, "#{dom}-thumb-log-1")
      refute has_element?(view, "#evidence-lightbox")

      view |> element("#{dom}-thumb-shot-2") |> render_click()
      assert has_element?(view, "#evidence-lightbox-image[src='#{path.("shot-2")}']")
      assert has_element?(view, "#evidence-lightbox-position", "2 of 2")

      view |> element("#evidence-lightbox-next") |> render_click()
      assert has_element?(view, "#evidence-lightbox-image[src='#{path.("shot-1")}']")

      render_keydown(view, "evidence_key", %{"key" => "ArrowLeft"})
      assert has_element?(view, "#evidence-lightbox-image[src='#{path.("shot-2")}']")
      assert has_element?(view, "#evidence-lightbox-original[href='#{path.("shot-2")}']")

      render_keydown(view, "close_evidence", %{"key" => "Escape"})
      refute has_element?(view, "#evidence-lightbox")
      refute render(view) =~ "X-Amz-Signature"
    end

    test "a scenario with no image evidence has no thumbnails", ctx do
      cr = head_cr!(ctx)
      fm = diff_fm(sha(1), [scenario("retry-backoff")])
      digest = upload_set!(ctx, cr.number, set_body_with_cli_digests(fm))
      log = "log"

      _run =
        final_run!(ctx, digest, "diff", [result("retry-backoff", "failed", ["log-1"])], [
          {artifact("log-1", log, "text/plain"), log}
        ])

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      toggle(view, "diff", "retry-backoff")

      assert has_element?(view, "#scenario-diff-retry-backoff-evidence-log-1")
      refute has_element?(view, "#scenario-diff-retry-backoff-gallery")
    end

    test "a set with no counted run shows the text and says there is no result", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"scenarios" => %{"require_approved_intent" => true}})
      cr = head_cr!(ctx, %{"change_id" => "add-export"})
      fm = intent_fm("add-export", [scenario("S1")])
      digest = upload_set!(ctx, cr.number, set_body_with_cli_digests(fm))
      _run = final_run!(ctx, digest, "intent", [result("S1")])

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      toggle(view, "intent", "S1")

      assert has_element?(view, "#qa-set-intent-run", "No counted run")
      assert has_element?(view, "#scenario-intent-S1-text", "Why: S1.")
      assert has_element?(view, "#scenario-intent-S1-no-result", "No verify run result")
    end

    test "a merged change request shows the same details from its stored verdict", ctx do
      cr = head_cr!(ctx)
      fm = diff_fm(sha(1), [scenario("D1")])
      digest = upload_set!(ctx, cr.number, set_body_with_cli_digests(fm, %{"D1" => @steps}))
      shot = "shot bytes"

      failed =
        result("D1", "failed", ["shot-1"])
        |> Map.merge(%{"failed_step" => "2", "reason" => "Title was wiped"})

      run = final_run!(ctx, digest, "diff", [failed], [{artifact("shot-1", shot), shot}])
      merge!(ctx, cr.number)

      _later = final_run!(ctx, digest, "diff", [result("D1")])

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#qa-frozen")
      toggle(view, "diff", "D1")

      assert has_element?(view, "#scenario-diff-D1-text > ol > li", "Send PATCH /todos/1")
      assert has_element?(view, "#scenario-diff-D1-failed-step", "Failed at 2")
      assert has_element?(view, "#scenario-diff-D1-reason", "Title was wiped")

      assert has_element?(
               view,
               "#scenario-diff-D1-thumb-shot-1 img[src$='/verify-runs/#{run.run_id}/artifacts/shot-1']"
             )
    end
  end
end
