defmodule GoodFlowsWeb.Api.V1.ChangeRequestJSON do
  @moduledoc """
  Renders change requests, their Git facts, claims and verdict.

  Public keys (`redact?: true`) see, without any stored row changing and
  without gaining absent fields: every `user_id` and `links.threads` (when
  present) as null; `description` as null; claims with `document` null and
  only `format`, `cr`, `head` and `door` in `front_matter`; Git facts with
  every commit's `changed_files` and `diff.files` null (`totals` stay); and
  every verdict and merge reason with `subject` and `message` null; the
  verdict's `coverage.unmapped_areas` null and each mapped feature's `id`
  null (`driven` stays). Verdict `scenarios` (IDs, priorities, results and
  run IDs) and `counted_runs` are shown to every key.
  """

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.ChangeRequests.{ChangeRequest, Claims, Event, GitFacts, Verdict}

  @public_front_matter ~w(format cr head door)

  @doc "Renders one change request with its description, verdict and history."
  def show(%{loaded: loaded, redact?: redact?}) do
    data =
      loaded.change_request
      |> record(redact?)
      |> Map.merge(%{
        description: if(redact?, do: nil, else: loaded.description),
        verdict: verdict_data(loaded.verdict, redact?),
        history: Enum.map(loaded.history, &event(&1, redact?))
      })

    %{data: data}
  end

  @doc "Renders one page of change requests."
  def index(%{change_requests: change_requests, next_cursor: next_cursor, redact?: redact?}) do
    %{data: Enum.map(change_requests, &record(&1, redact?)), next_cursor: next_cursor}
  end

  @doc "Renders a verdict read."
  def verdict(%{verdict: verdict, redact?: redact?}), do: %{data: verdict_data(verdict, redact?)}

  @doc "Renders stored Git facts with `totals`, the uploader and the upload time."
  def git_facts(%{git_facts: %GitFacts{} = facts, redact?: redact?}) do
    files = facts.document["diff"]["files"]

    totals = %{
      files: length(files),
      additions: files |> Enum.map(& &1["additions"]) |> Enum.sum(),
      deletions: files |> Enum.map(& &1["deletions"]) |> Enum.sum()
    }

    document = if redact?, do: redact_git_facts(facts.document), else: facts.document

    %{
      data:
        Map.merge(document, %{
          "totals" => totals,
          "user_id" => user_id(facts.account_user, redact?),
          "inserted_at" => DateTime.to_iso8601(facts.inserted_at)
        })
    }
  end

  @doc "Renders stored claims: the raw `document` and the parsed `front_matter`."
  def claims(%{claims: %Claims{} = claims, redact?: redact?}) do
    %{
      data: %{
        head: claims.head,
        document: if(redact?, do: nil, else: claims.document),
        front_matter:
          if(redact?,
            do: Map.take(claims.front_matter, @public_front_matter),
            else: claims.front_matter
          ),
        user_id: user_id(claims.account_user, redact?),
        inserted_at: DateTime.to_iso8601(claims.inserted_at)
      }
    }
  end

  defp record(%ChangeRequest{} = change_request, redact?) do
    %{
      id: change_request.id,
      number: change_request.number,
      title: change_request.title,
      state: change_request.state,
      source_branch: change_request.source_branch,
      target_branch: change_request.target_branch,
      openspec_change: change_request.openspec_change,
      links: links(change_request.links, redact?),
      head: change_request.head,
      parent: change_request.parent && change_request.parent.number,
      opened_by: %{user_id: user_id(change_request.opened_by_account_user, redact?)},
      merge: merge(change_request, redact?),
      inserted_at: DateTime.to_iso8601(change_request.inserted_at),
      updated_at: DateTime.to_iso8601(change_request.updated_at)
    }
  end

  defp links(%{"threads" => _threads} = links, true), do: %{links | "threads" => nil}
  defp links(links, _redact?), do: links

  defp merge(%ChangeRequest{state: "merged"} = change_request, redact?) do
    %{
      merged_commit: change_request.merged_commit,
      target_branch: change_request.merged_target_branch,
      merged_at: DateTime.to_iso8601(change_request.merged_at),
      head: change_request.merged_head,
      verdict_state: change_request.merged_verdict_state,
      policy_version: change_request.merged_policy_version,
      reasons: reasons(change_request.merged_reasons, redact?),
      merged_without_mergeable_verdict: change_request.merged_without_mergeable_verdict,
      merged_without_lease: change_request.merged_without_lease
    }
  end

  defp merge(%ChangeRequest{}, _redact?), do: nil

  defp verdict_data(nil, _redact?), do: nil

  defp verdict_data(%Verdict{} = verdict, redact?) do
    %{
      state: verdict.state,
      head: verdict.head,
      policy_version: verdict.policy_version,
      reasons: reasons(verdict.reasons, redact?),
      inputs: verdict.inputs,
      scenarios: verdict.scenarios || %{"intent" => nil, "diff" => nil},
      coverage: coverage(verdict.coverage, redact?),
      counted_runs: verdict.counted_runs,
      review: verdict.review || %{"items" => 0, "cleared" => 0},
      computed_at: DateTime.to_iso8601(verdict.computed_at)
    }
  end

  defp coverage(nil, _redact?), do: %{"version" => nil, "unmapped_areas" => [], "features" => []}
  defp coverage(coverage, false), do: coverage

  defp coverage(coverage, true) do
    %{
      coverage
      | "unmapped_areas" => nil,
        "features" => Enum.map(coverage["features"], &%{&1 | "id" => nil})
    }
  end

  defp reasons(reasons, false), do: reasons

  defp reasons(reasons, true),
    do: Enum.map(reasons, &%{&1 | "subject" => nil, "message" => nil})

  defp event(%Event{} = event, redact?) do
    %{
      from_state: event.from_state,
      to_state: event.to_state,
      user_id: user_id(event.account_user, redact?),
      inserted_at: DateTime.to_iso8601(event.inserted_at)
    }
  end

  defp user_id(_account_user, true), do: nil
  defp user_id(%AccountUser{user_id: id}, false), do: id
  defp user_id(_account_user, false), do: nil

  defp redact_git_facts(document) do
    commits = Enum.map(document["commits"], &%{&1 | "changed_files" => nil})
    %{document | "commits" => commits, "diff" => %{document["diff"] | "files" => nil}}
  end
end
