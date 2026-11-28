defmodule GoodFlowsWeb.StoredChangeLiveTest do
  use GoodFlowsWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import Phoenix.LiveViewTest

  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Repo
  alias GoodFlows.StoredChanges
  alias GoodFlows.StoredChanges.Files
  alias GoodFlows.StoredChanges.Version

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture()
    member = account_user_fixture(account, user, :member)
    owner = account_user_fixture(account, user_fixture(%{email: "pusher@example.com"}), :owner)
    {key, _token} = api_key_fixture(owner, %{type: :private})
    project = project_fixture(account, %{slug: "web"})
    api = project_fixture(account, %{slug: "api"})
    %{account: account, member: member, key: key, project: project, api: api}
  end

  @commit "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

  defp list_path(ctx, query \\ ""),
    do: "/dashboard/accounts/#{ctx.account.id}/projects/web/changes#{query}"

  defp show_path(ctx, id, query \\ ""), do: list_path(ctx) <> "/#{id}#{query}"

  defp change_md(id, opts) do
    fields =
      [
        {"format", "goodflows-change/1"},
        {"id", id},
        {"status", Keyword.get(opts, :status, "proposed")},
        {"size", Keyword.get(opts, :size, "small")},
        {"door", Keyword.get(opts, :door, "two_way")},
        {"capabilities", Keyword.get(opts, :capabilities, ["auth"])},
        {"depends_on", Keyword.get(opts, :depends_on, [])},
        {"goals", Keyword.get(opts, :goals, "[]")}
      ]

    yaml =
      Enum.map_join(fields, "\n", fn
        {key, list} when is_list(list) -> "#{key}: [#{Enum.join(list, ", ")}]"
        {key, value} -> "#{key}: #{value}"
      end)

    "---\n#{yaml}\n---\n\n" <> Keyword.get(opts, :body, "## Why\n\nBecause.\n")
  end

  defp qa_md(id) do
    """
    ---
    format: qa-scenarios/2
    source: intent
    change: "#{id}"
    specs: uncommitted
    review: null
    scenarios:
      - id: 1
        name: "Log in"
        priority: must
    ---

    # QA
    """
  end

  defp store!(ctx, id, opts \\ []) do
    files =
      Map.merge(
        %{"change.md" => Keyword.get(opts, :change_md) || change_md(id, opts)},
        Keyword.get(opts, :files, %{})
      )

    source = %{
      "commit" => Keyword.get(opts, :commit, @commit),
      "branch" => Keyword.get(opts, :branch, "feat/login"),
      "dirty" => Keyword.get(opts, :dirty, false)
    }

    project = Keyword.get(opts, :project, ctx.project)

    {:ok, :created, version, _replaced} =
      StoredChanges.push(project, ctx.key, %{"files" => files, "source" => source})

    version
  end

  defp cr!(ctx, change_id, state \\ "open") do
    {:ok, cr} =
      ChangeRequests.create(ctx.account, ctx.project, ctx.key, %{
        "title" => "Change #{System.unique_integer([:positive])}",
        "source_branch" => "feat/#{System.unique_integer([:positive])}",
        "change_id" => change_id
      })

    Repo.update_all(from(c in ChangeRequest, where: c.id == ^cr.id), set: [state: state])
    cr
  end

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
  end

  # The same, for a page that redirects (and so exits) on the refresh.
  defp project_event_redirect(view, ctx) do
    :erlang.trace(view.pid, true, [:receive])

    Phoenix.PubSub.broadcast(
      GoodFlows.PubSub,
      ProjectEvents.topic(ctx.project.id),
      {:project_event, ctx.project.id}
    )

    assert_receive {:trace, _pid, :receive, :refresh}, 2_000
    assert_redirect(view, 2_000)
  end

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#changes > tr")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "changes-row-", ""))
  end

  defp server_events("[" <> _ = js) do
    for ["push", %{"event" => event}] <- Jason.decode!(js), do: event
  end

  defp server_events(event), do: [event]

  defp file(path), do: "#files [data-path='#{path}']"
  defp diff(path), do: "#version-changes [data-path='#{path}']"

  describe "access (scenario 1)" do
    test "a member with role member opens the list and the detail page", ctx do
      store!(ctx, "add-login")
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert row_ids(view) == ["add-login"]

      assert has_element?(
               view,
               "#change-link-add-login[href='#{show_path(ctx, "add-login")}']"
             )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))
      assert has_element?(view, "#change-id", "add-login")
    end

    test "a signed-out visitor is sent to the log-in page", ctx do
      store!(ctx, "add-login")

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), show_path(ctx, "add-login"))
    end
  end

  describe "unknown project, change and version (scenario 2)" do
    test "another account's project redirects to the Projects page", ctx do
      other = project_fixture(account_fixture(), %{slug: "elsewhere"})
      store!(ctx, "theirs", project: other)

      for path <- [
            "/dashboard/accounts/#{ctx.account.id}/projects/elsewhere/changes",
            "/dashboard/accounts/#{ctx.account.id}/projects/elsewhere/changes/theirs"
          ] do
        assert {:error, {:live_redirect, %{to: to, flash: flash}}} = live(ctx.conn, path)
        assert to == "/dashboard/accounts/#{ctx.account.id}/projects"
        assert flash["error"] =~ "not found"
      end
    end

    test "a change of another project, or an unknown version, redirects to the list", ctx do
      store!(ctx, "api-only", project: ctx.api)
      store!(ctx, "add-login")

      for path <- [
            show_path(ctx, "api-only"),
            show_path(ctx, "add-login", "?version=99"),
            show_path(ctx, "add-login", "?version=abc"),
            show_path(ctx, "add-login", "?version=0"),
            show_path(ctx, "add-login", "?version[]=1"),
            show_path(ctx, "add-login", "?version[a]=1")
          ] do
        assert {:error, {:live_redirect, %{to: to, flash: flash}}} = live(ctx.conn, path)
        assert to == list_path(ctx)
        assert flash["error"] =~ "not found"
      end
    end

    test "a version param that is not a string gets a sentence saying so", ctx do
      store!(ctx, "add-login")

      for query <- ["?version[]=1", "?version[a]=1"] do
        assert {:error, {:live_redirect, %{flash: flash}}} =
                 live(ctx.conn, show_path(ctx, "add-login", query))

        assert flash["error"] ==
                 "Version not found: the version in the link is not a number. Versions of " <>
                   "add-login are numbered from 1; pick one from the change's History."
      end
    end
  end

  describe "read only (scenario 3)" do
    test "no page offers to edit or delete a change, and nothing is deleted", ctx do
      store!(ctx, "add-login")
      overview = "/dashboard/accounts/#{ctx.account.id}/projects/web"

      for path <- [list_path(ctx), show_path(ctx, "add-login"), overview] do
        {:ok, view, html} = live(ctx.conn, path)
        document = LazyHTML.from_fragment(html)

        controls =
          document
          |> LazyHTML.query("button, a, form")
          |> Enum.map(&LazyHTML.text/1)

        refute Enum.any?(controls, &(&1 =~ ~r/\b(delete|edit|remove)\b/i)), path

        events =
          document
          |> LazyHTML.query("[phx-click], [phx-submit]")
          |> Enum.flat_map(
            &(LazyHTML.attribute(&1, "phx-click") ++ LazyHTML.attribute(&1, "phx-submit"))
          )

        # The Changes list's filter bar edits the filter, not a change.
        filter_events =
          document
          |> LazyHTML.query("#changes-filter [phx-click], #changes-filter [phx-submit]")
          |> Enum.flat_map(
            &(LazyHTML.attribute(&1, "phx-click") ++ LazyHTML.attribute(&1, "phx-submit"))
          )

        # Server events only: a JS command counts by the events it pushes.
        events = Enum.flat_map(events -- filter_events, &server_events/1)
        refute Enum.any?(events, &(&1 =~ ~r/delete|edit|remove/i)), inspect({path, events})
        _ = render(view)
      end

      assert {:ok, _} = StoredChanges.get(ctx.project, "add-login")
    end
  end

  describe "list (scenarios 4, 5, 6, 7)" do
    test "defaults to active changes, newest push first, and filters by URL", ctx do
      store!(ctx, "a", status: "archived")
      store!(ctx, "b", status: "approved")
      store!(ctx, "c", status: "proposed")

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))
      assert row_ids(view) == ["c", "b"]

      assert has_element?(
               view,
               ~s(#filter-chip-status [data-selected="active"][aria-selected="true"])
             )

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?status=archived"))
      assert row_ids(view) == ["a"]

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?status=all"))
      assert row_ids(view) == ["c", "b", "a"]

      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?status=bogus"))
      assert row_ids(view) == ["c", "b"]

      assert has_element?(
               view,
               ~s(#filter-chip-status [data-selected="active"][aria-selected="true"])
             )
    end

    test "Load more shows the 51st change", ctx do
      for i <- 1..51, do: store!(ctx, "change-#{i}")
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert length(row_ids(view)) == 50
      view |> element("#load-more") |> render_click()
      assert length(row_ids(view)) == 51
      refute has_element?(view, "#load-more")
    end

    test "rows show metadata and linked change requests", ctx do
      store!(ctx, "add-login")
      latest = store!(ctx, "add-login", body: "## Why\n\nBecause, again.\n")
      cr12 = cr!(ctx, "add-login")
      cr9 = cr!(ctx, "add-login", "closed")

      {:ok, view, _html} = live(ctx.conn, list_path(ctx))
      row = "#changes-row-add-login"

      assert has_element?(view, "#{row} #change-status-add-login", "Proposed")
      assert has_element?(view, "#{row} #change-size-add-login .font-mono", "small")
      assert has_element?(view, "#{row} #change-door-add-login .font-mono", "two_way")
      assert has_element?(view, "#{row} #change-capabilities-add-login", "auth")
      assert has_element?(view, "#{row} #change-version-add-login", "2")

      assert has_element?(
               view,
               "#{row} #change-pushed-add-login",
               Calendar.strftime(latest.inserted_at, "%Y-%m-%d %H:%M UTC")
             )

      cr_path = "/dashboard/accounts/#{ctx.account.id}/projects/web/change-requests"

      for {cr, state} <- [{cr12, "Open"}, {cr9, "Closed"}] do
        assert has_element?(
                 view,
                 "#{row} #change-add-login-cr-#{cr.number}[href='#{cr_path}/#{cr.number}']",
                 "##{cr.number}"
               )

        assert has_element?(view, "#{row} #change-add-login-cr-#{cr.number}-state", state)
      end

      {:error, {:live_redirect, %{to: to}}} =
        view |> element("#change-add-login-cr-#{cr12.number}") |> render_click()

      assert to == "#{cr_path}/#{cr12.number}"
    end

    test "a missing size or door is a muted dash, like missing capabilities", ctx do
      store!(ctx, "add-login", size: "huge", door: "sideways", capabilities: [])
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      for field <- ~w(size door capabilities) do
        cell = "#changes-row-add-login #change-#{field}-add-login"
        assert has_element?(view, "#{cell} .text-muted", "—")
        refute has_element?(view, "#{cell} .font-mono")
      end

      document = view |> render() |> LazyHTML.from_fragment()

      for field <- ~w(size door) do
        td = LazyHTML.query(document, "td:has(> #change-#{field}-add-login)")
        refute td |> LazyHTML.attribute("class") |> Enum.join(" ") =~ "font-mono"
      end
    end

    test "an empty project explains goodflows change push", ctx do
      {:ok, view, _html} = live(ctx.conn, list_path(ctx))

      assert has_element?(view, "#changes-empty", "goodflows change push")
      assert has_element?(view, "#changes-empty", "newer than 0.10.0")
      refute has_element?(view, "#changes-filter-empty")
    end

    test "a filter that matches nothing names the filter", ctx do
      store!(ctx, "add-login")
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?status=archived"))

      assert has_element?(view, "#changes-filter-empty", "archived")
      refute has_element?(view, "#changes-empty")
    end
  end

  describe "detail header (scenario 10)" do
    test "shows the version's fields, and depends_on links only stored changes", ctx do
      store!(ctx, "add-users")

      version =
        store!(ctx, "add-login",
          dirty: true,
          depends_on: ["add-users", "add-ghost"],
          size: "project",
          door: "one_way",
          capabilities: ["auth", "auth/session"]
        )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#change-id", "add-login")
      assert has_element?(view, "#change-version", "1")
      assert has_element?(view, "#change-status", "Proposed")
      assert has_element?(view, "#change-size .font-mono", "project")
      assert has_element?(view, "#change-door .font-mono", "one_way")
      assert has_element?(view, "#change-capabilities", "auth/session")
      assert has_element?(view, "#change-commit", "a1b2c3d")
      refute has_element?(view, "#change-commit", @commit)
      assert has_element?(view, "#change-branch", "feat/login")
      assert has_element?(view, "#change-dirty", "Dirty")
      assert has_element?(view, "#change-pusher", "pusher@example.com")

      assert has_element?(
               view,
               "#change-pushed-at",
               Calendar.strftime(version.inserted_at, "%Y-%m-%d %H:%M UTC")
             )

      assert has_element?(view, "a#depends-on-add-users[href='#{show_path(ctx, "add-users")}']")
      assert has_element?(view, "#depends-on-add-ghost", "add-ghost")
      refute has_element?(view, "a#depends-on-add-ghost")
      refute has_element?(view, "#not-latest-notice")
    end

    test "null fields show as not given, no commit and a detached HEAD", ctx do
      store!(ctx, "add-login")

      store!(ctx, "add-login",
        commit: nil,
        branch: nil,
        size: "huge",
        door: "sideways",
        capabilities: ["Not Valid"]
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#change-version", "2")
      assert has_element?(view, "#change-commit", "No commit")
      assert has_element?(view, "#change-branch", "Detached HEAD")
      assert has_element?(view, "#change-dirty", "Clean")
      assert has_element?(view, "#change-size", "Not given")
      assert has_element?(view, "#change-door", "Not given")
      assert has_element?(view, "#change-capabilities", "Not given")
      assert has_element?(view, "#change-depends-on", "None")

      # "Not given" uses the same type in every field.
      refute has_element?(view, "#change-size .font-mono")
      refute has_element?(view, "#change-door .font-mono")
    end

    test "an empty capabilities list shows as none and a malformed depends_on as not given",
         ctx do
      store!(ctx, "add-login", capabilities: [], depends_on: ["Not Valid"])

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#change-capabilities", "None")
      refute has_element?(view, "#change-capabilities", "Not given")
      assert has_element?(view, "#change-depends-on", "Not given")
      refute has_element?(view, "#change-depends-on", "None")
    end
  end

  describe "linked change requests (scenario 11)" do
    test "lists each linked change request with its state", ctx do
      store!(ctx, "add-login")
      cr12 = cr!(ctx, "add-login")
      cr9 = cr!(ctx, "add-login", "closed")
      cr_path = "/dashboard/accounts/#{ctx.account.id}/projects/web/change-requests"

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      for {cr, state} <- [{cr12, "Open"}, {cr9, "Closed"}] do
        assert has_element?(
                 view,
                 "#linked-change-requests a#linked-cr-#{cr.number}[href='#{cr_path}/#{cr.number}']"
               )

        assert has_element?(view, "#linked-cr-#{cr.number}-state", state)
      end

      refute has_element?(view, "#no-change-requests")
    end

    test "says no change request exists when none links it", ctx do
      store!(ctx, "add-login")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#no-change-requests", "No change request")
    end
  end

  describe "file text (scenarios 12, 13)" do
    test "pushed HTML, script and unsafe links are not rendered", ctx do
      body = """
      ## Why

      <script>alert(1)</script>

      <img src=x onerror=alert(1)>

      [x](javascript:alert(1)) [y](JAVASCRIPT:alert(2)) [a](//evil.example/x) [b](#top) [ok](https://example.com/ok) [mail](mailto:a@example.com)
      """

      store!(ctx, "add-login", body: body)
      {:ok, view, html} = live(ctx.conn, show_path(ctx, "add-login"))

      markdown = "#{file("change.md")} .scenario-markdown"
      assert has_element?(view, markdown, "Why")
      refute has_element?(view, "#{markdown} script")
      refute has_element?(view, "#{markdown} img")
      refute has_element?(view, "#{markdown} [onerror]")
      refute html =~ "javascript:"
      refute html =~ ~r/javascript:/i
      refute has_element?(view, "#{markdown} a[href^='//']")
      refute has_element?(view, "#{markdown} a[href='#top']")
      assert has_element?(view, markdown, "a")
      assert has_element?(view, markdown, "b")
      assert has_element?(view, "#{markdown} a[href='https://example.com/ok']", "ok")
      assert has_element?(view, "#{markdown} a[href='mailto:a@example.com']", "mail")

      document = LazyHTML.from_fragment(html)
      hrefs = document |> LazyHTML.query("#files a") |> LazyHTML.attribute("href")
      assert Enum.sort(hrefs) == ["https://example.com/ok", "mailto:a@example.com"]
    end

    test "images keep only http(s) sources and every link form keeps only scheme targets",
         ctx do
      body = """
      ## Why

      ![remote](https://example.com/p.png) ![upper](HTTPS://example.com/q.png) ![rel](specs/p.png) ![proto](//evil.example/p.png) ![js](javascript:alert(1)) ![data](data:image/png;base64,AAAA)

      [Up](HTTPS://example.com/up) [Mail](MAILTO:b@example.com)

      [r1][ref1] [r2][ref2] [r3][ref3] [r4][ref4] <javascript:alert(3)> <https://example.com/auto>

      [ref1]: //evil.example/r
      [ref2]: specs/a.md
      [ref3]: javascript:alert(2)
      [ref4]: https://example.com/ref
      """

      store!(ctx, "add-login", body: body)
      {:ok, _view, html} = live(ctx.conn, show_path(ctx, "add-login"))

      markdown = LazyHTML.from_fragment(html) |> LazyHTML.query("#files .scenario-markdown")

      assert markdown |> LazyHTML.query("img") |> LazyHTML.attribute("src") == [
               "https://example.com/p.png",
               "https://example.com/q.png"
             ]

      text = LazyHTML.text(markdown)
      for alt <- ~w(rel proto js data r1 r2 r3), do: assert(text =~ alt)

      assert markdown |> LazyHTML.query("a") |> LazyHTML.attribute("href") |> Enum.sort() == [
               "https://example.com/auto",
               "https://example.com/ref",
               "https://example.com/up",
               "mailto:b@example.com"
             ]

      assert markdown |> LazyHTML.query("a:not([href])") |> Enum.count() == 0
      refute html =~ "evil.example/"
      refute html =~ "specs/p.png\""
    end

    test "front matter shows as a code block and the body as Markdown", ctx do
      store!(ctx, "add-login",
        goals: "[{id: G1, text: Log in}]",
        body: "## Why\n\nSee [the spec](specs/auth/spec.md).\n",
        files: %{"verification.md" => "---\nnot: closed\n\n## Checks\n\nRun it.\n"}
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#{file("change.md")} [data-role=front-matter]", "goals:")
      assert has_element?(view, "#{file("change.md")} .scenario-markdown h2", "Why")
      assert has_element?(view, "#{file("change.md")} .scenario-markdown", "the spec")
      refute has_element?(view, "#{file("change.md")} .scenario-markdown a")
      refute has_element?(view, "#{file("change.md")} .scenario-markdown", "goals:")

      view
      |> element("#{file("verification.md")} button[phx-click=toggle_file]")
      |> render_click()

      assert has_element?(view, "#{file("verification.md")} .scenario-markdown h2", "Checks")
      assert has_element?(view, "#{file("verification.md")} .scenario-markdown", "not: closed")
      refute has_element?(view, "#{file("verification.md")} [data-role=front-matter]")
    end

    test "a CRLF front matter is split like the server splits it", ctx do
      text = change_md("add-login", []) |> String.replace("\n", "\r\n")
      store!(ctx, "add-login", change_md: text)

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#{file("change.md")} [data-role=front-matter]", "status:")
      assert has_element?(view, "#{file("change.md")} .scenario-markdown h2", "Why")
    end
  end

  describe "collapsed and large files (scenario 14)" do
    test "change.md is expanded and the other files are collapsed until opened", ctx do
      store!(ctx, "add-login",
        files: %{
          "qa-scenarios.md" => qa_md("add-login"),
          "specs/auth/spec.md" => "## ADDED Requirements\n"
        }
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#{file("change.md")} [data-role=file-body]")
      refute has_element?(view, "#{file("qa-scenarios.md")} [data-role=file-body]")
      refute has_element?(view, "#{file("specs/auth/spec.md")} [data-role=file-body]")

      assert has_element?(
               view,
               "#{file("qa-scenarios.md")} button[phx-click=toggle_file][aria-expanded=false]"
             )

      view
      |> element("#{file("qa-scenarios.md")} button[phx-click=toggle_file]")
      |> render_click()

      assert has_element?(view, "#{file("qa-scenarios.md")} [data-role=file-body]")

      view |> element("#{file("change.md")} button[phx-click=toggle_file]") |> render_click()
      refute has_element?(view, "#{file("change.md")} [data-role=file-body]")
    end

    test "a file over 262,144 bytes is plain text and gets no line diff", ctx do
      big = "## Heading\n\n" <> String.duplicate("line of text\n", 23_100)
      assert byte_size(big) > 262_144 and byte_size(big) < 310_000
      store!(ctx, "add-login", files: %{"verification.md" => big})
      store!(ctx, "add-login", files: %{"verification.md" => big <> "one more\n"})

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      view
      |> element("#{file("verification.md")} button[phx-click=toggle_file]")
      |> render_click()

      assert has_element?(view, "#{file("verification.md")} [data-role=plain-text]", "## Heading")
      refute has_element?(view, "#{file("verification.md")} .scenario-markdown")
      assert has_element?(view, "#{file("verification.md")} [data-role=too-large]", "262,144")
      assert has_element?(view, "#{file("verification.md")} [data-role=too-large]", "repository")

      assert has_element?(
               view,
               "#{file("verification.md")} [data-role=plain-text].stored-change-plain-text"
             )

      assert has_element?(view, "#{diff("verification.md")}[data-change=changed]")
      refute has_element?(view, "#{diff("verification.md")} [data-role=line-diff]")
      assert has_element?(view, "#{diff("verification.md")} [data-role=no-diff]", "262,144")
      assert has_element?(view, "#{diff("verification.md")} [data-role=no-diff]", "git diff")

      store!(ctx, "add-login", files: %{"verification.md" => String.duplicate("x", 999) <> "\n"})
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#{diff("verification.md")}[data-change=changed]")
      refute has_element?(view, "#{diff("verification.md")} [data-role=line-diff]")
      assert has_element?(view, "#{diff("verification.md")} [data-role=no-diff]", "262,144")
    end
  end

  describe "the size limit counts UTF-8 bytes (scenario 14)" do
    test "a multibyte file over 262,144 bytes is plain text, one of exactly 262,144 renders",
         ctx do
      multibyte = "## Heading\n\n" <> String.duplicate("é", 140_000) <> "\n"
      assert String.length(multibyte) < 262_144 and byte_size(multibyte) > 262_144

      head = "## Heading\n\n"
      exact = head <> String.duplicate("x", 262_144 - byte_size(head) - 1) <> "\n"
      assert byte_size(exact) == 262_144

      store!(ctx, "add-login",
        files: %{"verification.md" => multibyte, "specs/exact/spec.md" => exact}
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      for path <- ["verification.md", "specs/exact/spec.md"] do
        view |> element("#{file(path)} button[phx-click=toggle_file]") |> render_click()
      end

      assert has_element?(view, "#{file("verification.md")} [data-role=plain-text]", "## Heading")
      refute has_element?(view, "#{file("verification.md")} .scenario-markdown")

      assert has_element?(view, "#{file("specs/exact/spec.md")} .scenario-markdown h2", "Heading")
      refute has_element?(view, "#{file("specs/exact/spec.md")} [data-role=too-large]")
    end

    test "a small file that grows over 262,144 bytes gets no line diff", ctx do
      big = "## Heading\n\n" <> String.duplicate("line of text\n", 23_100)
      store!(ctx, "add-login", files: %{"verification.md" => "## Heading\n"})
      store!(ctx, "add-login", files: %{"verification.md" => big})

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#{diff("verification.md")}[data-change=changed]")
      refute has_element?(view, "#{diff("verification.md")} [data-role=line-diff]")
      assert has_element?(view, "#{diff("verification.md")} [data-role=no-diff]", "262,144")
    end
  end

  describe "file ids" do
    test "paths that differ only in punctuation get distinct ids", ctx do
      # The push rules admit no such pair today, so the files are stored directly.
      version = store!(ctx, "add-login")
      files = Map.merge(version.files, %{"a.md" => "dot\n", "a_md" => "underscore\n"})
      Repo.update_all(from(v in Version, where: v.id == ^version.id), set: [files: files])
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      for path <- ["a.md", "a_md"] do
        view |> element("#{file(path)} button[phx-click=toggle_file]") |> render_click()
      end

      document = view |> render() |> LazyHTML.from_fragment()
      ids = document |> LazyHTML.query("#files > li") |> LazyHTML.attribute("id")
      assert length(ids) == 3 and length(Enum.uniq(ids)) == 3

      controls =
        document
        |> LazyHTML.query("#files button[aria-controls]")
        |> LazyHTML.attribute("aria-controls")

      assert length(controls) == 3 and length(Enum.uniq(controls)) == 3
      for id <- controls, do: assert(has_element?(view, "##{id}"))
      assert has_element?(view, "#{file("a.md")} [data-role=file-body]", "dot")
      assert has_element?(view, "#{file("a_md")} [data-role=file-body]", "underscore")
    end
  end

  describe "history (scenario 15)" do
    test "lists versions newest first and opens an earlier one", ctx do
      store!(ctx, "add-login", body: "one\n")
      store!(ctx, "add-login", body: "two\n", commit: "b" <> String.slice(@commit, 1..-1//1))
      store!(ctx, "add-login", body: "three\n", status: "approved")

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#history > li")
        |> LazyHTML.attribute("id")

      assert ids == ["history-3", "history-2", "history-1"]
      assert has_element?(view, "#history-3", "Approved")
      assert has_element?(view, "#history-1", "Proposed")
      assert has_element?(view, "#history-2", "b1b2c3d")
      assert has_element?(view, "#history-1", "pusher@example.com")
      assert has_element?(view, "#history-3 [data-role=viewed]")
      refute has_element?(view, "#history-1 [data-role=viewed]")
      assert has_element?(view, "#history-3 a[href='#{show_path(ctx, "add-login")}']")

      view |> element("#history-1 a") |> render_click()
      assert_patch(view, show_path(ctx, "add-login", "?version=1"))

      assert has_element?(view, "#change-version", "1")
      assert has_element?(view, "#change-status", "Proposed")
      assert has_element?(view, "#not-latest-notice", "3")
      assert has_element?(view, "#latest-version-link[href='#{show_path(ctx, "add-login")}']")
      assert has_element?(view, "#history-1 [data-role=viewed]")

      view |> element("#history-3 a") |> render_click()
      assert_patch(view, show_path(ctx, "add-login"))
      store!(ctx, "add-login", body: "four\n")
      project_event(view, ctx)

      assert has_element?(view, "#change-version", "4")
      refute has_element?(view, "#not-latest-notice")
    end

    test "History shows 50 versions and Load more shows the rest", ctx do
      for i <- 1..55, do: store!(ctx, "add-login", body: "push #{i}\n")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      count = fn ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#history > li")
        |> Enum.count()
      end

      assert count.() == 50
      view |> element("#history-load-more") |> render_click()
      assert count.() == 55
      assert has_element?(view, "#history-1")
      refute has_element?(view, "#history-load-more")
    end
  end

  describe "what changed (scenario 16)" do
    test "lists added, removed and changed files with a line diff", ctx do
      store!(ctx, "add-login",
        body: "## Why\n\nfirst line\nsecond line\n",
        files: %{"specs/auth/spec.md" => "## ADDED Requirements\n"}
      )

      store!(ctx, "add-login",
        body: "## Why\n\nfirst line\nsecond line edited\n",
        files: %{"qa-scenarios.md" => qa_md("add-login")}
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#{diff("qa-scenarios.md")}[data-change=added]")
      assert has_element?(view, "#{diff("specs/auth/spec.md")}[data-change=removed]")
      assert has_element?(view, "#{diff("change.md")}[data-change=changed]")

      paths =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#version-changes [data-path]")
        |> LazyHTML.attribute("data-path")

      assert Enum.sort(paths) == ["change.md", "qa-scenarios.md", "specs/auth/spec.md"]

      lines = "#{diff("change.md")} [data-role=line-diff]"
      # Long lines scroll inside the panel, so it must take keyboard focus to scroll.
      assert has_element?(view, ~s(#{lines}[tabindex="0"][aria-label="Line diff of change.md"]))
      assert has_element?(view, "#{lines} [data-op=del]", "second line")
      assert has_element?(view, "#{lines} [data-op=ins]", "second line edited")
      refute has_element?(view, "#{lines} [data-op=del]", "first line")

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login", "?version=1"))
      assert has_element?(view, "#{diff("change.md")}[data-change=added]")
      assert has_element?(view, "#{diff("specs/auth/spec.md")}[data-change=added]")
    end

    test "unchanged lines between edits fold into one row of plain text", ctx do
      old = Enum.map_join(1..20, &"line #{&1}\n")
      new = String.replace(old, "line 20\n", "line 20 edited\n")
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => old})
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => new})

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      skip =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#{diff("specs/auth/spec.md")} [data-op=skip] .stored-change-diff-text")

      assert LazyHTML.text(skip) == "16 unchanged lines"
    end

    test "the page renders the diff on the connected mount only", ctx do
      store!(ctx, "add-login", body: "## Why\n\none\n")
      store!(ctx, "add-login", body: "## Why\n\ntwo\n")

      html = ctx.conn |> get(show_path(ctx, "add-login")) |> html_response(200)
      refute html =~ ~s(data-role="line-diff")
      assert html =~ "Comparing the files"

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))
      assert has_element?(view, "#{diff("change.md")} [data-role=line-diff]")
      refute has_element?(view, "#version-changes-pending")
    end

    test "two versions of 1,000 lines together, every line different, get a line diff fast",
         ctx do
      old = Enum.map_join(1..500, &"a#{&1}\n")
      new = Enum.map_join(1..500, &"b#{&1}\n")
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => old})
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => new})

      {elapsed, {:ok, view, _html}} =
        :timer.tc(fn -> live(ctx.conn, show_path(ctx, "add-login")) end, :millisecond)

      assert elapsed < 1_000
      assert has_element?(view, "#{diff("specs/auth/spec.md")} [data-role=line-diff]")
      assert has_element?(view, "#{diff("specs/auth/spec.md")} [data-op=del]", "a500")
      assert has_element?(view, "#{diff("specs/auth/spec.md")} [data-op=ins]", "b500")
    end

    test "100 changed files at the per-file cap stay within the version's diff budget", ctx do
      paths = for i <- 1..99, do: "specs/cap-#{i}/spec.md"
      lines = fn tag, i -> Enum.map_join(1..500, &"#{tag}#{i}-#{&1}\n") end
      old = paths |> Enum.with_index() |> Map.new(fn {path, i} -> {path, lines.("a", i)} end)
      new = paths |> Enum.with_index() |> Map.new(fn {path, i} -> {path, lines.("b", i)} end)

      {elapsed, entries} =
        :timer.tc(fn -> Files.compare(old, new) end, :millisecond)

      assert elapsed < 1_000
      assert Enum.count(entries, &match?({:lines, _}, &1.diff)) == 1
      assert Enum.count(entries, &(&1.diff == {:skipped, :version_budget})) == 98

      store!(ctx, "add-login", files: old)
      store!(ctx, "add-login", files: new)

      {elapsed, {:ok, view, _html}} =
        :timer.tc(fn -> live(ctx.conn, show_path(ctx, "add-login")) end, :millisecond)

      assert elapsed < 1_500
      [first, second | _] = Enum.sort(paths)
      last = Enum.max(paths)
      assert has_element?(view, "#{diff(first)} [data-role=line-diff]")
      refute has_element?(view, "#{diff(second)} [data-role=line-diff]")
      refute has_element?(view, "#{diff(last)} [data-role=line-diff]")

      for path <- [second, last] do
        assert has_element?(view, "#{diff(path)} [data-role=no-diff]", "1,000 changed lines")
        assert has_element?(view, "#{diff(path)} [data-role=no-diff]", "git diff")
      end
    end

    test "a one-line edit in each of a change's own three files gives each a line diff",
         ctx do
      # Sized like this change's own files: change.md, qa-scenarios.md and one spec.
      numbered = fn prefix, n -> Enum.map_join(1..n, &"#{prefix} line #{&1}\n") end
      edit = fn text, line -> String.replace(text, line <> "\n", line <> " edited\n") end
      body = "## Why\n\n" <> numbered.("Why", 220)
      qa = qa_md("add-login") <> numbered.("QA", 265)
      spec = numbered.("Spec", 70)

      store!(ctx, "add-login",
        body: body,
        files: %{"qa-scenarios.md" => qa, "specs/auth/spec.md" => spec}
      )

      store!(ctx, "add-login",
        body: edit.(body, "Why line 100"),
        files: %{
          "qa-scenarios.md" => edit.(qa, "QA line 130"),
          "specs/auth/spec.md" => edit.(spec, "Spec line 35")
        }
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      for {path, line} <- [
            {"change.md", "Why line 100"},
            {"qa-scenarios.md", "QA line 130"},
            {"specs/auth/spec.md", "Spec line 35"}
          ] do
        assert has_element?(view, "#{diff(path)}[data-change=changed]")
        assert has_element?(view, "#{diff(path)} [data-op=del]", line)
        assert has_element?(view, "#{diff(path)} [data-op=ins]", line <> " edited")
        refute has_element?(view, "#{diff(path)} [data-role=no-diff]")
      end
    end

    test "a long file with a small edit gets a line diff numbered from its own lines", ctx do
      old = Enum.map_join(1..3_000, &"line #{&1}\n")
      new = String.replace(old, "line 1500\n", "line 1500 edited\n")
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => old})
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => new})

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))
      lines = "#{diff("specs/auth/spec.md")} [data-role=line-diff]"

      document = view |> render() |> LazyHTML.from_fragment()

      ops =
        document
        |> LazyHTML.query("#{lines} [data-op]")
        |> LazyHTML.attribute("data-op")

      assert ops == ~w(skip eq eq eq del ins eq eq eq skip)

      skips =
        document
        |> LazyHTML.query("#{lines} [data-op=skip]")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.trim/1)

      assert skips == ["1496 unchanged lines", "1497 unchanged lines"]

      numbers =
        document
        |> LazyHTML.query("#{lines} [data-op=del] .stored-change-diff-number")
        |> Enum.map(&LazyHTML.text/1)

      assert numbers == ["1500", ""]
      assert has_element?(view, "#{lines} [data-op=ins]", "line 1500 edited")
    end

    test "a file the version budget skips leaves the rest of the budget to later files",
         ctx do
      different = fn tag, n -> Enum.map_join(1..n, &"#{tag}#{&1}\n") end

      store!(ctx, "add-login",
        files: %{
          "specs/a/spec.md" => different.("a", 300),
          "specs/b/spec.md" => different.("b", 250),
          "specs/c/spec.md" => different.("c", 10)
        }
      )

      store!(ctx, "add-login",
        files: %{
          "specs/a/spec.md" => different.("A", 300),
          "specs/b/spec.md" => different.("B", 250),
          "specs/c/spec.md" => different.("C", 10)
        }
      )

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      assert has_element?(view, "#{diff("specs/a/spec.md")} [data-role=line-diff]")
      refute has_element?(view, "#{diff("specs/b/spec.md")} [data-role=line-diff]")

      assert has_element?(
               view,
               "#{diff("specs/b/spec.md")} [data-role=no-diff]",
               "1,000 changed lines"
             )

      assert has_element?(view, "#{diff("specs/c/spec.md")} [data-role=line-diff]")
      assert has_element?(view, "#{diff("specs/c/spec.md")} [data-op=ins]", "C10")
    end

    test "two versions of 1,001 lines together get no line diff", ctx do
      old = Enum.map_join(1..500, &"a#{&1}\n")
      new = Enum.map_join(1..501, &"b#{&1}\n")
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => old})
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => new})

      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      refute has_element?(view, "#{diff("specs/auth/spec.md")} [data-role=line-diff]")
      assert has_element?(view, "#{diff("specs/auth/spec.md")} [data-role=no-diff]", "1,000")
      assert has_element?(view, "#{diff("specs/auth/spec.md")} [data-role=no-diff]", "git diff")
    end

    test "two versions of 12,000 lines together get no line diff", ctx do
      old = Enum.map_join(1..6_000, &"a#{&1}\n")
      new = Enum.map_join(1..6_000, &"b#{&1}\n")
      assert byte_size(old) < 262_144 and byte_size(new) < 262_144
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => old})
      store!(ctx, "add-login", files: %{"specs/auth/spec.md" => new})

      {elapsed, {:ok, view, _html}} =
        :timer.tc(fn -> live(ctx.conn, show_path(ctx, "add-login")) end, :millisecond)

      assert elapsed < 2_000
      assert has_element?(view, "#{diff("specs/auth/spec.md")}[data-change=changed]")
      refute has_element?(view, "#{diff("specs/auth/spec.md")} [data-role=line-diff]")
      assert has_element?(view, "#{diff("specs/auth/spec.md")} [data-role=no-diff]", "1,000")
    end
  end

  describe "refresh (scenario 17)" do
    test "the list keeps its filter and loaded rows and shows the new push", ctx do
      for i <- 1..50, do: store!(ctx, "change-#{i}")
      store!(ctx, "add-login", status: "archived")
      {:ok, view, _html} = live(ctx.conn, list_path(ctx, "?status=all"))
      view |> element("#load-more") |> render_click()
      assert length(row_ids(view)) == 51

      version = store!(ctx, "change-1", body: "new\n")
      project_event(view, ctx)

      assert length(row_ids(view)) == 51
      assert hd(row_ids(view)) == "change-1"
      assert has_element?(view, "#change-version-change-1", "2")

      assert has_element?(
               view,
               "#change-pushed-change-1",
               Calendar.strftime(version.inserted_at, "%Y-%m-%d %H:%M UTC")
             )

      assert has_element?(
               view,
               ~s(#filter-chip-status [data-selected="all"][aria-selected="true"])
             )
    end

    test "the latest page follows a push and keeps expanded files; ?version=1 stays", ctx do
      files = %{"qa-scenarios.md" => qa_md("add-login")}
      store!(ctx, "add-login", files: files)
      {:ok, latest, _html} = live(ctx.conn, show_path(ctx, "add-login"))
      {:ok, pinned, _html} = live(ctx.conn, show_path(ctx, "add-login", "?version=1"))

      latest
      |> element("#{file("qa-scenarios.md")} button[phx-click=toggle_file]")
      |> render_click()

      store!(ctx, "add-login", files: files, body: "## Why\n\nNew.\n")
      project_event(latest, ctx)
      project_event(pinned, ctx)

      assert has_element?(latest, "#change-version", "2")
      assert has_element?(latest, "#{file("qa-scenarios.md")} [data-role=file-body]")
      assert has_element?(latest, "#history-2")

      assert has_element?(pinned, "#change-version", "1")
      assert has_element?(pinned, "#not-latest-notice", "2")
      assert has_element?(pinned, "#history-2")
    end
  end

  describe "deleted while open (scenario 18)" do
    test "redirects to the list with a deleted flash", ctx do
      store!(ctx, "add-login")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      :ok = StoredChanges.delete(ctx.project, ctx.key, "add-login")
      {path, flash} = project_event_redirect(view, ctx)
      assert path == list_path(ctx)
      assert flash["error"] =~ "add-login"
      assert flash["error"] =~ "deleted"
    end

    test "a change deleted and pushed again counts as deleted", ctx do
      store!(ctx, "add-login", body: "old\n")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      :ok = StoredChanges.delete(ctx.project, ctx.key, "add-login")
      store!(ctx, "add-login", body: "new\n")
      {path, flash} = project_event_redirect(view, ctx)
      assert path == list_path(ctx)
      assert flash["error"] =~ "deleted"
    end

    test "a change deleted before History loads more redirects with the deleted flash", ctx do
      for i <- 1..51, do: store!(ctx, "add-login", body: "push #{i}\n")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login"))

      :ok = StoredChanges.delete(ctx.project, ctx.key, "add-login")
      view |> element("#history-load-more") |> render_click()

      {path, flash} = assert_redirect(view)
      assert path == list_path(ctx)
      assert flash["error"] =~ "deleted"
    end

    test "a page pinned to a version redirects too", ctx do
      store!(ctx, "add-login")
      store!(ctx, "add-login", body: "two\n")
      {:ok, view, _html} = live(ctx.conn, show_path(ctx, "add-login", "?version=1"))

      :ok = StoredChanges.delete(ctx.project, ctx.key, "add-login")
      {path, _flash} = project_event_redirect(view, ctx)
      assert path == list_path(ctx)
    end
  end
end
