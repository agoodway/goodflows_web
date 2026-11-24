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

  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.Verdict
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Repo
  alias GoodFlows.Review.Answer

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
      closed = create!(ctx)
      close!(ctx, closed.number)
      Repo.update_all(Verdict, set: [state: "mergeable", review: %{"items" => 2, "cleared" => 2}])

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?state=merged"))
      assert has_element?(view, "#verdict-#{blocked.number}", "Blocked")
      assert has_element?(view, "#review-count-#{blocked.number}", "2 of 2")

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

    test "mergeable says no rule fired; no head says so", ctx do
      cr = create!(ctx)
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#no-head", "No head yet")

      facts!(ctx.sk_conn, ctx.slug, cr.number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, cr.number, sha(1), %{"cr" => cr.number})
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))
      assert has_element?(view, "#header-verdict", "Mergeable")
      assert has_element?(view, "#no-reasons", "No rule fired at this head.")
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

    test "a merged change request shows no items, the notice and Merged without a lease", ctx do
      cr = create!(ctx)
      one_way!(ctx, cr.number, sha(1))
      merge!(ctx, cr.number)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, cr.number))

      refute has_element?(view, "#review-panel")
      refute has_element?(view, "button[phx-click=open_answer]")
      assert has_element?(view, "#merged-unmergeable-notice", "Needs review")
      assert has_element?(view, "#merged-without-lease", "Merged without a lease")
      assert has_element?(view, "#header-verdict", "Needs review")
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
      cr = create!(ctx, %{"openspec_change" => "add-export"})
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
      number = create_cr(author, ctx.slug, %{"openspec_change" => "add-export"})["number"]

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

      number = create_cr(ctx.sk_conn, ctx.slug, %{"openspec_change" => "add-export"})["number"]

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

      number = create_cr(ctx.sk_conn, ctx.slug, %{"openspec_change" => "add-export"})["number"]

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
end
