defmodule GoodFlows.CalibrationTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.Calibration
  alias GoodFlows.Calibration.Defect
  alias GoodFlows.ChangeRequests.{ChangeRequest, GitFacts}
  alias GoodFlows.ProjectEvents.Event
  alias GoodFlows.Review.Answer
  alias GoodFlows.ReviewPolicies.Version

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "Cal #{System.unique_integer()}"})
    account_user = Accounts.get_account_user(user, account)
    {api_key, _token} = api_key_fixture(account_user, %{type: :private})
    %{account: account, api_key: api_key, project: project_fixture(account)}
  end

  @t0 ~U[2026-11-10 12:00:00.000000Z]

  # A merged change request inserted directly. Options: `:merged_at`,
  # `:policy_version`, `:reasons`, `:verdict` (merged_without_mergeable_verdict),
  # `:lease` (false sets merged_without_lease), `:commits` and `:files` for
  # its merged head's Git facts.
  defp merged(ctx, number, opts \\ []) do
    head = sha(10_000 + number)

    cr =
      Repo.insert!(%ChangeRequest{
        account_id: ctx.account.id,
        project_id: ctx.project.id,
        number: number,
        title: "t",
        source_branch: "b#{number}",
        target_branch: "main",
        state: "merged",
        head: head,
        merged_commit: sha(20_000 + number),
        merged_target_branch: "main",
        merged_at: Keyword.get(opts, :merged_at, @t0),
        merged_head: head,
        merged_verdict_state: "mergeable",
        merged_policy_version: Keyword.get(opts, :policy_version, 0),
        merged_reasons: Keyword.get(opts, :reasons, []),
        merged_without_mergeable_verdict: Keyword.get(opts, :verdict, false),
        merged_without_lease: not Keyword.get(opts, :lease, true)
      })

    files = Keyword.get(opts, :files, [file("lib/a.ex")])
    commits = Keyword.get(opts, :commits, [head])

    document =
      git_facts(head, files: files)
      |> Map.put(
        "commits",
        Enum.map(commits, &%{"sha" => &1, "parents" => [sha(0)], "changed_files" => files})
      )

    Repo.insert!(%GitFacts{
      change_request_id: cr.id,
      head: head,
      target_branch: "main",
      document: document,
      digest: :crypto.hash(:sha256, Jason.encode!(document))
    })

    cr
  end

  defp defect!(cr, attrs \\ []) do
    Repo.insert!(
      struct(
        %Defect{
          project_id: cr.project_id,
          change_request_id: cr.id,
          attribution: "change_request",
          recorded_at: Keyword.get(attrs, :recorded_at, DateTime.utc_now())
        },
        Keyword.delete(attrs, :recorded_at)
      )
    )
  end

  defp answered!(cr) do
    Repo.insert!(%Answer{
      change_request_id: cr.id,
      item_id: "one_way_door:x",
      kind: "one_way_door",
      rule: "one_way_door",
      head: cr.merged_head,
      answer: "approve",
      channel: "cli"
    })
  end

  defp report!(ctx, params \\ %{}) do
    params =
      Map.merge(%{"from" => "2026-11-01T00:00:00Z", "to" => "2026-11-20T00:00:00Z"}, params)

    {:ok, report} = Calibration.report(ctx.project, params)
    report
  end

  describe "record_defect/3" do
    test "by change request number, with severity and ticket", ctx do
      cr = merged(ctx, 42)

      assert {:ok, defect} =
               Calibration.record_defect(ctx.project, ctx.api_key, %{
                 "change_request" => 42,
                 "severity" => "high",
                 "ticket" => "GOO-512"
               })

      assert %Defect{attribution: "change_request", commit: nil, severity: "high"} = defect
      assert defect.change_request_id == cr.id
      assert defect.api_key_id == ctx.api_key.id
      assert defect.account_user_id == ctx.api_key.account_user_id

      assert [%Event{change_request_number: 42, data: data}] =
               Repo.all(from e in Event, where: e.type == "defect_recorded")

      assert data == %{
               "defect_id" => defect.id,
               "commit" => nil,
               "attribution" => "change_request",
               "severity" => "high",
               "ticket" => "GOO-512"
             }
    end

    test "a commit goes to the one merged change request that lists it", ctx do
      cr = merged(ctx, 42, commits: [sha(1), sha(2)])
      _other = merged(ctx, 43)

      assert {:ok, %Defect{attribution: "commit", change_request_id: id, commit: commit}} =
               Calibration.record_defect(ctx.project, ctx.api_key, %{"commit" => sha(1)})

      assert id == cr.id and commit == sha(1)
    end

    test "several matches pick the earliest merged", ctx do
      _late = merged(ctx, 41, commits: [sha(1)], merged_at: ~U[2026-11-03 09:00:00.000000Z])
      early = merged(ctx, 42, commits: [sha(1)], merged_at: ~U[2026-11-02 10:00:00.000000Z])

      assert {:ok, %Defect{change_request_id: id}} =
               Calibration.record_defect(ctx.project, ctx.api_key, %{"commit" => sha(1)})

      assert id == early.id
    end

    test "no match, or only an open change request, is unattributed with a null number", ctx do
      cr = merged(ctx, 57, commits: [sha(3)])
      Repo.update_all(from(c in ChangeRequest, where: c.id == ^cr.id), set: [state: "open"])

      for commit <- [sha(3), sha(4)] do
        assert {:ok, %Defect{attribution: "unattributed", change_request_id: nil}} =
                 Calibration.record_defect(ctx.project, ctx.api_key, %{"commit" => commit})
      end

      assert [nil, nil] =
               Repo.all(
                 from e in Event,
                   where: e.type == "defect_recorded",
                   select: e.change_request_number
               )
    end

    test "each invalid body is 422 on its field and records nothing", ctx do
      _cr = merged(ctx, 42)

      for {body, key} <- [
            {%{"change_request" => 42, "commit" => sha(1)}, "body"},
            {%{"severity" => "low"}, "body"},
            {%{"change_request" => 999}, "change_request"},
            {%{"commit" => "HEAD~1"}, "commit"},
            {%{"change_request" => 42, "severity" => "blocker"}, "severity"},
            {%{"change_request" => 42, "ticket" => ""}, "ticket"},
            {%{"change_request" => 42, "ticket" => String.duplicate("é", 201)}, "ticket"},
            {%{"change_request" => 42, "extra" => 1}, "body"}
          ] do
        assert {:error, {:invalid_body, errors}} =
                 Calibration.record_defect(ctx.project, ctx.api_key, body)

        assert Map.has_key?(errors, key), "#{inspect(body)}: #{inspect(errors)}"
      end

      assert {:ok, _} =
               Calibration.record_defect(ctx.project, ctx.api_key, %{
                 "change_request" => 42,
                 "ticket" => String.duplicate("é", 200)
               })

      assert Repo.aggregate(Defect, :count) == 1
      assert Repo.aggregate(from(e in Event, where: e.type == "defect_recorded"), :count) == 1
    end
  end

  describe "report/2" do
    test "the default window is the 90 days before now; a reversed window is 422", ctx do
      {:ok, report} = Calibration.report(ctx.project, %{})
      assert DateTime.diff(report.to, report.from, :day) == 90

      {:ok, report} = Calibration.report(ctx.project, %{"to" => "2026-11-21T00:00:00Z"})
      assert report.from == ~U[2026-08-23 00:00:00.000000Z]

      assert {:error, changeset} =
               Calibration.report(ctx.project, %{
                 "from" => "2026-11-10T00:00:00Z",
                 "to" => "2026-11-01T00:00:00Z"
               })

      assert %{from: [_]} = errors_on(changeset)
      assert {:error, _} = Calibration.report(ctx.project, %{"from" => "yesterday"})
    end

    test "the 20/5/3 auto lane example", ctx do
      crs = for n <- 1..20, do: merged(ctx, n)
      [a, b, c | _rest] = crs
      defect!(a)
      defect!(b)
      for _ <- 1..3, do: defect!(c)

      assert report!(ctx).lanes["auto"] == %{
               merged_count: 20,
               defect_count: 5,
               defective_count: 3,
               defect_rate: 0.15
             }

      assert report!(ctx).lanes["bypass"].defect_rate == nil
    end

    test "lanes: bypass wins over reviewed, reviewed over auto", ctx do
      auto = merged(ctx, 42)
      reviewed = merged(ctx, 43)
      answered!(reviewed)
      no_lease = merged(ctx, 44, lease: false)
      answered!(no_lease)
      _no_verdict = merged(ctx, 45, verdict: true)
      defect!(auto)

      lanes = report!(ctx).lanes
      assert lanes["auto"].merged_count == 1 and lanes["auto"].defect_count == 1
      assert lanes["reviewed"].merged_count == 1
      assert lanes["bypass"].merged_count == 2
    end

    test "window: merged_at in [from, to); defects counted whenever recorded", ctx do
      inside = merged(ctx, 42)
      _before = merged(ctx, 43, merged_at: ~U[2026-10-01 00:00:00.000000Z])
      _at_to = merged(ctx, 44, merged_at: ~U[2026-11-20 00:00:00.000000Z])
      defect!(inside, recorded_at: ~U[2026-12-01 00:00:00.000000Z])

      report = report!(ctx)
      assert report.lanes["auto"].merged_count == 1
      assert report.lanes["auto"].defect_count == 1
    end

    test "by policy version", ctx do
      Repo.insert!(%Version{
        project_id: ctx.project.id,
        version: 6,
        previous_version: 5,
        document: %{"format" => "review-policy/1"}
      })

      Repo.insert!(%Version{
        project_id: ctx.project.id,
        version: 7,
        previous_version: 6,
        document: %{"format" => "review-policy/1"}
      })

      _v6 = merged(ctx, 42, policy_version: 6)
      v7 = merged(ctx, 45, policy_version: 7)
      defect!(v7)

      assert [%{version: 6, lanes: l6}, %{version: 7, lanes: l7}] = report!(ctx).policy_versions
      assert %{merged_count: 1, defect_count: 0} = l6["auto"]
      assert %{merged_count: 1, defect_count: 1} = l7["auto"]
    end

    test "by rule, with gaps", ctx do
      path = %{
        "rule" => "path_match",
        "outcome" => "needs_review",
        "subject" => [],
        "message" => ""
      }

      _a = merged(ctx, 42, reasons: [path])
      b = merged(ctx, 43, reasons: [path])
      gap = merged(ctx, 46)
      _clean = merged(ctx, 47)
      defect!(b)
      defect!(gap, severity: "critical")

      report = report!(ctx)
      assert [%{rule: "path_match", fired_count: 2, fired_with_defects_count: 1}] = report.rules
      assert report.gaps == [46]
    end

    test "by glob: a commit's changed files, else the merged head's diff", ctx do
      Repo.insert!(%Version{
        project_id: ctx.project.id,
        version: 1,
        previous_version: 0,
        document: %{
          "format" => "review-policy/1",
          "paths" => [%{"glob" => "app/priv/repo/migrations/**", "outcome" => "needs_review"}]
        }
      })

      migration = file("app/priv/repo/migrations/20261101_add.exs")
      sweep = file("app/lib/good_flows/caches/sweep.ex")
      by_commit = merged(ctx, 42, commits: [sha(1)], files: [migration], policy_version: 1)
      by_number = merged(ctx, 43, files: [sweep], policy_version: 1)

      {:ok, _} = Calibration.record_defect(ctx.project, ctx.api_key, %{"commit" => sha(1)})
      defect!(by_number)
      assert Repo.get_by!(Defect, change_request_id: by_commit.id).attribution == "commit"

      report = report!(ctx)
      assert [%{glob: "app/priv/repo/migrations/**", defect_count: 1}] = report.globs
      assert report.unmatched_defect_count == 1
    end

    test "a defect of a change request merged with no head is unmatched", ctx do
      {:ok, cr} =
        GoodFlows.ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, %{
          "title" => "t",
          "source_branch" => "b"
        })

      {:ok, merged} =
        GoodFlows.ChangeRequests.report_merge(cr, ctx.api_key, %{
          "merged_commit" => sha(500),
          "target_branch" => cr.target_branch
        })

      assert merged.merged_head == nil

      {:ok, _} =
        Calibration.record_defect(ctx.project, ctx.api_key, %{"change_request" => merged.number})

      assert {:ok, report} = Calibration.report(ctx.project, %{})
      assert report.unmatched_defect_count == 1
    end

    test "reading the report and recording defects create no policy version or verdict", ctx do
      cr = merged(ctx, 42)
      {:ok, _} = Calibration.record_defect(ctx.project, ctx.api_key, %{"change_request" => 42})
      _ = report!(ctx)

      assert Repo.aggregate(Version, :count) == 0
      assert Repo.get(GoodFlows.ChangeRequests.Verdict, cr.id) == nil

      refute Repo.exists?(
               from e in Event, where: e.type in ["verdict_changed", "policy_version_created"]
             )
    end
  end
end
