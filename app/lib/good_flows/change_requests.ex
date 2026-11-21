defmodule GoodFlows.ChangeRequests do
  @moduledoc """
  Change requests (the `change-requests` capability): records that replace
  pull requests, their lifecycle, the Git facts and claims a client reports
  for each head, and the verdict computed from them and the project's
  review policy.

  Every change request starts as `draft` with the next number of its
  project, taken from `projects.change_request_seq` under that row's lock,
  so numbers are distinct and never reused. `transition/3` moves it
  between `draft`, `open` and `closed`; `report_merge/3` records the merge
  and the verdict at the head and makes it `merged`, which is terminal.
  Each state change stores an event with the membership and key.

  Git facts (`report_git_facts/3`) are immutable per head and target
  branch, and claims (`upload_claims/3`) per head; an exact retry is
  `:ok`, a different document `{:error, :git_facts_conflict}` or
  `{:error, :claims_conflict}`. The last reported head is current.

  Writes lock the change request row (`FOR UPDATE`) and recompute its
  verdict (`recompute/2`) in the same transaction. A workflow run upload
  on a change request's head (`recompute_for_commit/3`) and a new policy
  version (`recompute_after_policy_write/1`) recompute too. A Git facts
  report and a workflow run upload on the same commit serialize on a
  transaction-level advisory lock keyed on (project, commit), so one of
  them always recomputes with both. `closed` and `merged` verdicts are
  never recomputed.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.ChangeRequests.{ChangeRequest, Claims, ClaimsDocument, Event}
  alias GoodFlows.ChangeRequests.{GitFacts, GitFactsValidator, Params, RecomputeJob, Rules}
  alias GoodFlows.ChangeRequests.Verdict
  alias GoodFlows.JsonDocument
  alias GoodFlows.KeysetCursor
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.WorkflowRuns.Run
  alias GoodFlows.WorkflowRuns.Validator, as: RunValidator

  @active_states ~w(draft open)
  @default_page_size 50
  @max_page_size 200
  @default_inline_recompute_limit 100

  @typedoc "A change request with what a show response needs."
  @type loaded :: %{
          change_request: ChangeRequest.t(),
          description: String.t() | nil,
          verdict: Verdict.t() | nil,
          history: [Event.t()]
        }

  @typedoc "A state change action."
  @type action :: :ready | :draft | :close | :reopen

  @doc """
  Opens a draft change request in `project` from a normalized create body,
  recording `api_key` and its membership as the opener. `target_branch`
  defaults to the project's `default_branch`.
  """
  @spec create(Account.t(), Project.t(), ApiKey.t(), term()) ::
          {:ok, ChangeRequest.t()} | {:error, :not_found | {:invalid_body, map()}}
  def create(%Account{id: account_id}, %Project{account_id: account_id} = project, api_key, body) do
    with {:ok, attrs} <- Params.create(body) do
      Repo.transaction(fn ->
        {number, default_branch} = next_number(project)

        change_request =
          %ChangeRequest{
            account_id: account_id,
            project_id: project.id,
            number: number,
            state: "draft",
            opened_by_account_user_id: api_key.account_user_id,
            opened_by_api_key_id: api_key.id
          }
          |> ChangeRequest.create_changeset(Map.put_new(attrs, :target_branch, default_branch))
          |> Repo.insert!()

        recompute(change_request)
        change_request
      end)
    end
  end

  def create(%Account{}, %Project{}, _api_key, _body), do: {:error, :not_found}

  defp next_number(project) do
    query =
      from p in Project,
        where: p.id == ^project.id,
        select: {p.change_request_seq, p.default_branch}

    case Repo.update_all(query, inc: [change_request_seq: 1]) do
      {1, [result]} -> result
      {0, _} -> Repo.rollback(:not_found)
    end
  end

  @doc "The change request `number` of `project`."
  @spec get(Project.t(), pos_integer()) :: {:ok, ChangeRequest.t()} | {:error, :not_found}
  def get(%Project{id: project_id}, number) when is_integer(number) do
    case Repo.get_by(ChangeRequest, project_id: project_id, number: number) do
      nil -> {:error, :not_found}
      change_request -> {:ok, change_request}
    end
  end

  @doc """
  One page of `project`'s change requests, `number` descending. Params:
  `"limit"` (1 to #{@max_page_size}, default #{@default_page_size}),
  `"cursor"`, and the exact filters `"state"` and `"source_branch"`.
  """
  @spec list(Project.t(), map()) ::
          {:ok, %{change_requests: [ChangeRequest.t()], next_cursor: String.t() | nil}}
          | {:error, Ecto.Changeset.t()}
  def list(%Project{id: project_id}, params) do
    with {:ok, filters} <- list_params(params) do
      change_requests =
        ChangeRequest
        |> where(project_id: ^project_id)
        |> filter(:state, filters.state)
        |> filter(:source_branch, filters.source_branch)
        |> after_cursor(filters.cursor)
        |> order_by(desc: :number)
        |> limit(^(filters.limit + 1))
        |> preload(:opened_by_account_user)
        |> Repo.all()

      {page, rest} = Enum.split(change_requests, filters.limit)
      next = if rest != [], do: KeysetCursor.encode_integer(List.last(page).number)
      {:ok, %{change_requests: page, next_cursor: next}}
    end
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: where(query, [c], field(c, ^field) == ^value)

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, number), do: where(query, [c], c.number < ^number)

  defp list_params(params) do
    types = %{limit: :integer, cursor: :string, state: :string, source_branch: :string}

    {%{limit: @default_page_size, cursor: nil, state: nil, source_branch: nil}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types), empty_values: [])
    |> Ecto.Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_page_size
    )
    |> Ecto.Changeset.validate_inclusion(:state, ChangeRequest.states())
    |> Ecto.Changeset.validate_change(:source_branch, fn :source_branch, value ->
      if RunValidator.valid_branch?(value), do: [], else: [source_branch: "is invalid"]
    end)
    |> KeysetCursor.put_cursor(&KeysetCursor.decode_integer/1)
    |> Ecto.Changeset.apply_action(:list)
  end

  @doc """
  Loads what a show response needs: the opener, the description (the
  claims file for the current head, or nil), the verdict and the history
  oldest first.
  """
  @spec load(ChangeRequest.t()) :: loaded()
  def load(%ChangeRequest{} = change_request) do
    change_request = Repo.preload(change_request, :opened_by_account_user, force: true)

    history =
      Repo.all(
        from e in Event,
          where: e.change_request_id == ^change_request.id,
          order_by: [asc: e.inserted_at, asc: e.id],
          preload: :account_user
      )

    %{
      change_request: change_request,
      description: description(change_request),
      verdict: Repo.get(Verdict, change_request.id),
      history: history
    }
  end

  defp description(%ChangeRequest{head: nil}), do: nil

  defp description(%ChangeRequest{id: id, head: head}) do
    Repo.one(
      from c in Claims, where: c.change_request_id == ^id and c.head == ^head, select: c.document
    )
  end

  @doc "The stored verdict, or nil."
  @spec verdict(ChangeRequest.t()) :: Verdict.t() | nil
  def verdict(%ChangeRequest{id: id}), do: Repo.get(Verdict, id)

  @doc """
  Applies a state change. Asking for the current state is `{:ok, cr}`
  with nothing recorded; any other move the lifecycle does not allow is
  `{:error, :invalid_transition}`. Reopen restores the state from before
  the close.
  """
  @spec transition(ChangeRequest.t(), ApiKey.t(), action()) ::
          {:ok, ChangeRequest.t()} | {:error, :invalid_transition}
  def transition(%ChangeRequest{} = change_request, %ApiKey{} = api_key, action) do
    Repo.transaction(fn ->
      change_request = lock(change_request)

      case next_state(change_request, action) do
        :same ->
          change_request

        {:ok, to} ->
          updated =
            change_request |> ChangeRequest.state_changeset(to) |> Repo.update!()

          record_event(change_request.state, to, change_request, api_key)
          recompute(updated)
          updated

        :conflict ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  defp next_state(%ChangeRequest{state: "draft"}, :ready), do: {:ok, "open"}
  defp next_state(%ChangeRequest{state: "open"}, :ready), do: :same
  defp next_state(%ChangeRequest{state: "open"}, :draft), do: {:ok, "draft"}
  defp next_state(%ChangeRequest{state: "draft"}, :draft), do: :same

  defp next_state(%ChangeRequest{state: state}, :close) when state in @active_states,
    do: {:ok, "closed"}

  defp next_state(%ChangeRequest{state: "closed"}, :close), do: :same

  defp next_state(%ChangeRequest{state: "closed", closed_from_state: from}, :reopen),
    do: {:ok, from || "draft"}

  defp next_state(%ChangeRequest{state: state}, :reopen) when state in @active_states, do: :same
  defp next_state(%ChangeRequest{}, _action), do: :conflict

  defp record_event(from, to, change_request, api_key) do
    %Event{}
    |> Event.changeset(%{
      change_request_id: change_request.id,
      from_state: from,
      to_state: to,
      account_user_id: api_key.account_user_id,
      api_key_id: api_key.id
    })
    |> Repo.insert!()
  end

  defp lock(%ChangeRequest{id: id}) do
    Repo.one!(from c in ChangeRequest, where: c.id == ^id, lock: "FOR UPDATE")
  end

  @doc """
  Records a merge report from a normalized body. Accepted from `draft` or
  `open`: the stored verdict's state (`pending` without a head), policy
  version and reasons are kept with the merge, and
  `merged_without_mergeable_verdict` is set when that state is not
  `mergeable`. On a `merged` change request the same `merged_commit` and
  `target_branch` return the stored merge unchanged; anything else is
  `:merge_conflict`. A `closed` change request is `:invalid_transition`.
  """
  @spec report_merge(ChangeRequest.t(), ApiKey.t(), term()) ::
          {:ok, ChangeRequest.t()}
          | {:error, :invalid_transition | :merge_conflict | {:invalid_body, map()}}
  def report_merge(%ChangeRequest{} = change_request, %ApiKey{} = api_key, body) do
    with {:ok, attrs} <- Params.merge(body) do
      Repo.transaction(fn -> merge_locked(lock(change_request), api_key, attrs) end)
    end
  end

  defp merge_locked(%ChangeRequest{state: "merged"} = change_request, _api_key, attrs) do
    if change_request.merged_commit == attrs.merged_commit and
         change_request.merged_target_branch == attrs.target_branch,
       do: change_request,
       else: Repo.rollback(:merge_conflict)
  end

  defp merge_locked(%ChangeRequest{state: state} = change_request, api_key, attrs)
       when state in @active_states do
    verdict = Repo.get(Verdict, change_request.id)
    verdict_state = if change_request.head && verdict, do: verdict.state, else: "pending"

    merge = %{
      merged_commit: attrs.merged_commit,
      target_branch: attrs.target_branch,
      merged_at: DateTime.utc_now(),
      head: change_request.head,
      verdict_state: verdict_state,
      policy_version:
        if(verdict, do: verdict.policy_version, else: current_policy_version(change_request)),
      reasons: if(verdict, do: verdict.reasons, else: []),
      merged_without_mergeable_verdict: verdict_state != "mergeable"
    }

    updated = change_request |> ChangeRequest.merge_changeset(merge) |> Repo.update!()
    record_event(state, "merged", change_request, api_key)
    updated
  end

  defp merge_locked(%ChangeRequest{}, _api_key, _attrs), do: Repo.rollback(:invalid_transition)

  defp current_policy_version(change_request),
    do: ReviewPolicies.current(change_request.project_id).version

  @doc """
  Stores a `git-facts/1` report from a normalized body for a `draft` or
  `open` change request and makes its head current. Returns `{:ok,
  :created, cr}` for a new head and target branch, `{:ok, :retry, cr}` for
  an equal document, or `:git_facts_conflict`, `:not_active` or
  `{:invalid_body, errors}`.
  """
  @spec report_git_facts(ChangeRequest.t(), ApiKey.t(), term()) ::
          {:ok, :created | :retry, ChangeRequest.t()}
          | {:error, :not_active | :git_facts_conflict | {:invalid_body, map()}}
  def report_git_facts(%ChangeRequest{} = change_request, %ApiKey{} = api_key, body) do
    with :ok <- require_active(change_request),
         {:ok, document} <- GitFactsValidator.validate(body, change_request.target_branch) do
      Repo.transaction(fn -> report_git_facts_locked(change_request, api_key, document) end)
      |> unwrap_status()
    end
  end

  defp report_git_facts_locked(change_request, api_key, document) do
    lock_head(change_request.project_id, document["head"])
    change_request = lock_active(change_request)
    status = store_git_facts(change_request, api_key, document)
    updated = put_head(change_request, document["head"])
    recompute(updated)
    {status, updated}
  end

  defp lock_active(change_request) do
    change_request = lock(change_request)
    if require_active(change_request) != :ok, do: Repo.rollback(:not_active)
    change_request
  end

  defp store_git_facts(change_request, api_key, document) do
    digest = JsonDocument.digest(document)

    row = %{
      id: Ecto.UUID.generate(),
      change_request_id: change_request.id,
      head: document["head"],
      target_branch: document["target"]["branch"],
      document: document,
      digest: digest,
      account_user_id: api_key.account_user_id,
      api_key_id: api_key.id,
      inserted_at: DateTime.utc_now()
    }

    case Repo.insert_all(GitFacts, [row],
           on_conflict: :nothing,
           conflict_target: [:change_request_id, :head, :target_branch],
           log: false
         ) do
      {1, _} ->
        :created

      {0, _} ->
        stored =
          Repo.one(
            from f in GitFacts,
              where:
                f.change_request_id == ^row.change_request_id and f.head == ^row.head and
                  f.target_branch == ^row.target_branch,
              select: f.digest
          )

        if stored == digest, do: :retry, else: Repo.rollback(:git_facts_conflict)
    end
  end

  defp put_head(%ChangeRequest{head: head} = change_request, head), do: change_request

  defp put_head(change_request, head),
    do: change_request |> ChangeRequest.head_changeset(head) |> Repo.update!()

  @doc """
  Stores a `change-claims/2` file (raw bytes) for the current head of a
  `draft` or `open` change request. Returns `{:ok, :created, cr}`, `{:ok,
  :retry, cr}` for identical bytes, or `:claims_conflict` (different file
  for the head), `:not_active` or `{:invalid_body, errors}`.
  """
  @spec upload_claims(ChangeRequest.t(), ApiKey.t(), binary()) ::
          {:ok, :created | :retry, ChangeRequest.t()}
          | {:error, :not_active | :claims_conflict | {:invalid_body, map()}}
  def upload_claims(%ChangeRequest{} = change_request, %ApiKey{} = api_key, raw)
      when is_binary(raw) do
    with :ok <- require_active(change_request),
         {:ok, front_matter} <- ClaimsDocument.parse(raw) do
      Repo.transaction(fn -> upload_claims_locked(change_request, api_key, raw, front_matter) end)
      |> unwrap_status()
    end
  end

  defp upload_claims_locked(change_request, api_key, raw, front_matter) do
    change_request = lock_active(change_request)

    context = %{
      number: change_request.number,
      head: change_request.head,
      diff_paths: diff_paths(change_request)
    }

    with {:error, reason} <- ClaimsDocument.validate(front_matter, context),
         do: Repo.rollback(reason)

    status = store_claims(change_request, api_key, raw, front_matter)
    recompute(change_request)
    {status, change_request}
  end

  defp diff_paths(%ChangeRequest{head: nil}), do: nil

  defp diff_paths(change_request) do
    case current_facts(change_request) do
      nil ->
        nil

      %GitFacts{document: document} ->
        document["diff"]["files"]
        |> Enum.flat_map(&[&1["path"], &1["old_path"]])
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()
    end
  end

  defp store_claims(change_request, api_key, raw, front_matter) do
    digest = :crypto.hash(:sha256, raw)

    stored =
      Repo.one(
        from c in Claims,
          where: c.change_request_id == ^change_request.id and c.head == ^front_matter["head"],
          select: c.digest
      )

    cond do
      stored == digest ->
        :retry

      stored != nil ->
        Repo.rollback(:claims_conflict)

      true ->
        %Claims{}
        |> Claims.changeset(%{
          change_request_id: change_request.id,
          head: front_matter["head"],
          document: raw,
          front_matter: front_matter,
          digest: digest,
          account_user_id: api_key.account_user_id,
          api_key_id: api_key.id
        })
        |> Repo.insert!(log: false)

        :created
    end
  end

  defp require_active(%ChangeRequest{state: state}) when state in @active_states, do: :ok
  defp require_active(%ChangeRequest{}), do: {:error, :not_active}

  defp unwrap_status({:ok, {status, change_request}}), do: {:ok, status, change_request}
  defp unwrap_status({:error, reason}), do: {:error, reason}

  @doc """
  The Git facts stored for `head` and `target` (default: the change
  request's `target_branch`), with the uploader's membership preloaded.
  """
  @spec get_git_facts(ChangeRequest.t(), String.t(), String.t() | nil) ::
          {:ok, GitFacts.t()} | {:error, :not_found}
  def get_git_facts(%ChangeRequest{} = change_request, head, target \\ nil) do
    target = target || change_request.target_branch

    case Repo.one(
           from f in GitFacts,
             where:
               f.change_request_id == ^change_request.id and f.head == ^head and
                 f.target_branch == ^target,
             preload: :account_user
         ) do
      nil -> {:error, :not_found}
      facts -> {:ok, facts}
    end
  end

  @doc "The claims stored for `head`, with the uploader's membership preloaded."
  @spec get_claims(ChangeRequest.t(), String.t()) :: {:ok, Claims.t()} | {:error, :not_found}
  def get_claims(%ChangeRequest{id: id}, head) do
    case Repo.one(
           from c in Claims,
             where: c.change_request_id == ^id and c.head == ^head,
             preload: :account_user
         ) do
      nil -> {:error, :not_found}
      claims -> {:ok, claims}
    end
  end

  defp current_facts(%ChangeRequest{head: nil}), do: nil

  defp current_facts(%ChangeRequest{} = change_request) do
    Repo.one(
      from f in GitFacts,
        where:
          f.change_request_id == ^change_request.id and f.head == ^change_request.head and
            f.target_branch == ^change_request.target_branch
    )
  end

  @doc """
  Recomputes and stores the verdict of a `draft` or `open` change request
  for its current head with `policy` (default: the project's current
  policy, `GoodFlows.ReviewPolicies.compiled/1`). `closed` and `merged`
  change requests are skipped. Call it inside the transaction that changed
  an input.
  """
  @spec recompute(ChangeRequest.t(), Rules.policy() | nil) :: :ok | :skipped
  def recompute(change_request, policy \\ nil)

  def recompute(%ChangeRequest{state: state} = change_request, policy)
      when state in @active_states do
    policy = policy || ReviewPolicies.compiled(change_request.project_id)
    facts = current_facts(change_request)

    verdict =
      Rules.evaluate(%{
        head: change_request.head,
        git_facts: facts && %{document: facts.document, digest: facts.digest},
        claims: facts && current_claims(change_request),
        workflows: required_workflows(change_request, policy),
        policy: policy
      })

    Repo.insert!(
      %Verdict{
        change_request_id: change_request.id,
        state: verdict.state,
        head: verdict.head,
        policy_version: verdict.policy_version,
        reasons: verdict.reasons,
        inputs: verdict.inputs,
        computed_at: DateTime.utc_now()
      },
      on_conflict: {:replace_all_except, [:change_request_id]},
      conflict_target: :change_request_id
    )

    :ok
  end

  def recompute(%ChangeRequest{}, _policy), do: :skipped

  defp current_claims(%ChangeRequest{id: id, head: head}) do
    Repo.one(
      from c in Claims,
        where: c.change_request_id == ^id and c.head == ^head,
        select: %{front_matter: c.front_matter, digest: c.digest}
    )
  end

  # The newest run (by `started_at`, then `run_id`) of each required
  # workflow on the head whose `source.dirty` is not true. Served by
  # `workflow_runs_required_workflow_index`.
  defp required_workflows(%ChangeRequest{head: nil}, _policy), do: %{}

  defp required_workflows(change_request, policy) do
    names = policy.effective["evidence"]["required_workflows"]

    found =
      if names == [] do
        %{}
      else
        Repo.all(
          from r in Run,
            where:
              r.account_id == ^change_request.account_id and
                r.project_id == ^change_request.project_id and
                r.source_commit == ^change_request.head and r.workflow in ^names and
                (is_nil(r.source_dirty) or r.source_dirty == false),
            distinct: r.workflow,
            order_by: [desc: r.started_at, desc: r.run_id],
            select: {r.workflow, %{outcome: r.outcome, run_id: type(r.run_id, :string)}}
        )
        |> Map.new()
      end

    Map.new(names, &{&1, Map.get(found, &1)})
  end

  @doc """
  Recomputes every `draft` or `open` change request of the project whose
  head is `commit`. Called in the transaction that stores a workflow run.
  """
  @spec recompute_for_commit(Ecto.UUID.t(), String.t() | nil) :: :ok
  def recompute_for_commit(_project_id, nil), do: :ok

  def recompute_for_commit(project_id, commit) do
    lock_head(project_id, commit)

    change_requests =
      Repo.all(
        from c in ChangeRequest,
          where: c.project_id == ^project_id and c.head == ^commit and c.state in @active_states,
          order_by: c.id,
          lock: "FOR UPDATE"
      )

    if change_requests != [] do
      policy = ReviewPolicies.compiled(project_id)
      Enum.each(change_requests, &recompute(&1, policy))
    end

    :ok
  end

  # Serializes a Git facts report that moves a head to `commit` with a
  # workflow run stored on `commit`. Without it, under READ COMMITTED, the
  # run's `recompute_for_commit/2` skips a change request whose head update
  # is not committed yet, while the facts report cannot see the uncommitted
  # run, and neither recomputes with both. Taken before any change request
  # row lock in both paths, so the lock order is the same and cannot
  # deadlock.
  defp lock_head(project_id, commit) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('change_request_head:' || $1 || ':' || $2, 0))",
      [project_id, commit],
      log: false
    )

    :ok
  end

  @doc """
  After a new policy version: recomputes every `draft` and `open` change
  request of `project` in the caller's transaction when there are at most
  `config :good_flows, :change_request_inline_recompute_limit` (default
  #{@default_inline_recompute_limit}), otherwise enqueues
  `GoodFlows.ChangeRequests.RecomputeJob`.
  """
  @spec recompute_after_policy_write(Project.t()) :: :ok | {:enqueued, String.t()}
  def recompute_after_policy_write(%Project{id: project_id}) do
    limit =
      Application.get_env(
        :good_flows,
        :change_request_inline_recompute_limit,
        @default_inline_recompute_limit
      )

    count =
      Repo.aggregate(
        from(c in ChangeRequest,
          where: c.project_id == ^project_id and c.state in @active_states
        ),
        :count
      )

    if count <= limit do
      recompute_project(project_id)
      :ok
    else
      case PgFlow.enqueue(RecomputeJob, %{"project_id" => project_id}) do
        {:ok, run_id} -> {:enqueued, run_id}
        {:error, reason} -> Repo.rollback({:enqueue_failed, reason})
      end
    end
  end

  @doc """
  Recomputes every `draft` and `open` change request of the project, in
  one transaction, and returns how many were recomputed.
  """
  @spec recompute_project(Ecto.UUID.t()) :: non_neg_integer()
  def recompute_project(project_id) do
    {:ok, count} =
      Repo.transaction(fn ->
        change_requests =
          Repo.all(
            from c in ChangeRequest,
              where: c.project_id == ^project_id and c.state in @active_states,
              order_by: c.id,
              lock: "FOR UPDATE"
          )

        policy = ReviewPolicies.compiled(project_id)
        Enum.each(change_requests, &recompute(&1, policy))
        length(change_requests)
      end)

    count
  end
end
