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
  verdict (`recompute/2`) in the same transaction. A transaction that
  locks several change request rows locks them in `number` order. A
  parent always has a lower number than its child, so this order is
  parent-first, and paths that lock one row and then more (a parent, then
  its children; a parent `FOR SHARE`, then the child) follow it too. A workflow run upload
  on a change request's head (`recompute_for_commit/3`) and a new policy
  version (`recompute_after_policy_write/1`) recompute too. A Git facts
  report and a workflow run upload on the same commit serialize on a
  transaction-level advisory lock keyed on (project, commit), so one of
  them always recomputes with both. `closed` and `merged` verdicts are
  never recomputed.

  A recompute resolves a `needs_review` verdict with the review answers at
  the head (`GoodFlows.Review.Items.resolve/3`) and records a
  `verdict_changed` event when anything the verdict shows changed: its
  state, head, policy version, reasons, scenarios, coverage, counted runs
  or review counts. State changes and merge reports record
  `cr_state_changed`, a retarget `cr_retargeted` and a parent change
  `cr_parent_changed`, and a new head makes the change request's `open`
  review tasks `stale`.

  History that outlives the event retention is kept in the same
  transactions: a Git facts report that stores a row records its
  `previous_head` and `head_kind`; a recompute that stores the first
  verdict or changes its state, head or policy version appends a
  `VerdictTransition`, and every recompute opens and closes `ReasonSpan`s
  by diffing the new reasons against the open spans. A merge closes the
  open spans with `merged` and stores `fix_iterations` and `head_count`;
  a close closes them with `closed`.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.ChangeRequests.{ChangeRequest, Claims, ClaimsDocument, Event}

  alias GoodFlows.ChangeRequests.{
    GitFacts,
    GitFactsValidator,
    Grading,
    Params,
    ReasonSpan,
    RecomputeJob,
    Rules
  }

  alias GoodFlows.ChangeRequests.{Verdict, VerdictTransition}
  alias GoodFlows.JsonDocument
  alias GoodFlows.KeysetCursor
  alias GoodFlows.MergeLeases
  alias GoodFlows.MergeLeases.Lease
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.Review
  alias GoodFlows.Review.Items
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.WorkflowRuns.Run
  alias GoodFlows.WorkflowRuns.Validator, as: RunValidator

  @active_states ~w(draft open)
  @default_page_size 50
  @max_page_size 200
  @default_inline_recompute_limit 100
  @retarget_attempts 3

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

  Options, which the API never sets: `states:` keeps only change requests
  in one of the given states (the dashboard's Active filter passes
  `~w(draft open)`), and `preload:` adds associations to preload, such as
  `[:verdict]`.
  """
  @spec list(Project.t(), map(), keyword()) ::
          {:ok, %{change_requests: [ChangeRequest.t()], next_cursor: String.t() | nil}}
          | {:error, Ecto.Changeset.t()}
  def list(%Project{id: project_id}, params, opts \\ []) do
    with {:ok, filters} <- list_params(params) do
      change_requests =
        ChangeRequest
        |> where(project_id: ^project_id)
        |> filter(:state, filters.state)
        |> filter_states(Keyword.get(opts, :states))
        |> filter(:source_branch, filters.source_branch)
        |> after_cursor(filters.cursor)
        |> order_by(desc: :number)
        |> limit(^(filters.limit + 1))
        |> preload(^([:opened_by_account_user, :parent] ++ Keyword.get(opts, :preload, [])))
        |> Repo.all()

      {page, rest} = Enum.split(change_requests, filters.limit)
      next = if rest != [], do: KeysetCursor.encode_integer(List.last(page).number)
      {:ok, %{change_requests: page, next_cursor: next}}
    end
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: where(query, [c], field(c, ^field) == ^value)

  defp filter_states(query, nil), do: query
  defp filter_states(query, states), do: where(query, [c], c.state in ^states)

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
    change_request =
      Repo.preload(change_request, [:opened_by_account_user, :parent], force: true)

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
  The change request's verify runs (`Grading.runs_on_sets/2`). For a
  `draft` or `open` change request each has the `explanation` of
  `Grading.explain_runs/4` at the current head and policy. A `merged` or
  `closed` one's policy, facts and approvals may have changed since its
  stored verdict, so its runs have no `explanation`, and only runs stored
  at or before `frozen_at` (its verdict's `computed_at`) are listed.
  """
  @spec verify_runs(ChangeRequest.t(), DateTime.t() | nil) :: [map()]
  def verify_runs(change_request, frozen_at \\ nil)

  def verify_runs(%ChangeRequest{state: state} = change_request, _frozen_at)
      when state in @active_states do
    policy = ReviewPolicies.compiled(change_request.project_id)
    facts = current_facts(change_request)
    document = facts && facts.document
    grading = Grading.load(change_request, document, policy)
    Grading.explain_runs(change_request, document, policy, grading)
  end

  def verify_runs(%ChangeRequest{} = change_request, frozen_at),
    do: Grading.runs_on_sets(change_request, frozen_at)

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
          move(change_request, api_key, to)

        :conflict ->
          Repo.rollback(:invalid_transition)
      end
    end)
  end

  defp move(change_request, api_key, to) do
    children = lock_children(change_request)

    ended =
      if to == "closed",
        do: MergeLeases.release_held(change_request, "closed", DateTime.utc_now()),
        else: []

    updated = change_request |> ChangeRequest.state_changeset(to) |> Repo.update!()
    record_event(change_request.state, to, change_request, api_key)
    if to == "closed", do: close_open_spans(change_request, "closed", DateTime.utc_now())
    recompute(updated)
    record_state_changed(change_request, to, api_key)
    MergeLeases.record_ended(ended, api_key)
    recompute_children(children)
    updated
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

  defp record_state_changed(change_request, to, api_key) do
    ProjectEvents.record(
      change_request.project_id,
      change_request.number,
      "cr_state_changed",
      %{"from" => change_request.state, "to" => to},
      Review.cli_actor(api_key)
    )
  end

  defp lock(%ChangeRequest{id: id}) do
    Repo.one!(from c in ChangeRequest, where: c.id == ^id, lock: "FOR UPDATE")
  end

  # The `draft` and `open` children of a change request, locked after it
  # and in `number` order (parents before children, the order of every
  # multi-row lock) and before any event is recorded.
  defp lock_children(%ChangeRequest{id: id}) do
    Repo.all(
      from c in ChangeRequest,
        where: c.parent_id == ^id and c.state in @active_states,
        order_by: c.number,
        lock: "FOR UPDATE"
    )
  end

  defp recompute_children([]), do: :ok

  defp recompute_children([child | _rest] = children) do
    policy = ReviewPolicies.compiled(child.project_id)
    Enum.each(children, &recompute(&1, policy))
  end

  @doc """
  Records a merge report from a normalized body. Accepted from `draft` or
  `open`: the stored verdict's state (`pending` without a head), policy
  version and reasons are kept with the merge, and
  `merged_without_mergeable_verdict` is set when that state is not
  `mergeable`. A held lease is released with `release_reason: "merged"`
  (one past its time is expired), without recomputing the verdict;
  `merged_without_lease` is false only when `lease_id` names the lease
  released that way. On a `merged` change request the same
  `merged_commit` and `target_branch` return the stored merge unchanged,
  whatever else the body carries; anything else is `:merge_conflict`. A
  `closed` change request is `:invalid_transition`.
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
    children = lock_children(change_request)
    now = DateTime.utc_now()
    ended = MergeLeases.release_held(change_request, "merged", now)

    leased? =
      attrs.lease_id != nil and
        Enum.any?(ended, fn {kind, lease} -> kind == :released and lease.id == attrs.lease_id end)

    verdict = Repo.get(Verdict, change_request.id)
    verdict_state = if change_request.head && verdict, do: verdict.state, else: "pending"

    merge = %{
      merged_commit: attrs.merged_commit,
      target_branch: attrs.target_branch,
      merged_at: now,
      head: change_request.head,
      verdict_state: verdict_state,
      policy_version:
        if(verdict, do: verdict.policy_version, else: current_policy_version(change_request)),
      reasons: if(verdict, do: verdict.reasons, else: []),
      merged_without_mergeable_verdict: verdict_state != "mergeable",
      merged_without_lease: not leased?,
      fix_iterations: fix_iterations(change_request),
      head_count: head_count(change_request)
    }

    updated = change_request |> ChangeRequest.merge_changeset(merge) |> Repo.update!()
    close_open_spans(change_request, "merged", now)
    record_event(state, "merged", change_request, api_key)
    record_state_changed(change_request, "merged", api_key)
    MergeLeases.record_ended(ended, api_key)
    recompute_children(children)
    updated
  end

  defp merge_locked(%ChangeRequest{}, _api_key, _attrs), do: Repo.rollback(:invalid_transition)

  defp fix_iterations(change_request) do
    if history_predates_head_kinds?(change_request),
      do: nil,
      else: count_fixes_after_a_grade(change_request)
  end

  defp history_predates_head_kinds?(%ChangeRequest{id: id}),
    do:
      Repo.exists?(from f in GitFacts, where: f.change_request_id == ^id and is_nil(f.head_kind))

  defp count_fixes_after_a_grade(%ChangeRequest{id: id}) do
    replaced_head_was_graded_earlier =
      from g in VerdictTransition,
        where:
          g.change_request_id == ^id and g.to_head == parent_as(:fix).from_head and
            g.to_state in ~w(blocked needs_review) and
            g.inserted_at < parent_as(:fix).inserted_at,
        select: 1

    Repo.aggregate(
      from(t in VerdictTransition,
        as: :fix,
        where:
          t.change_request_id == ^id and t.cause == "head" and
            t.head_kind in ~w(fast_forward rewrite) and exists(replaced_head_was_graded_earlier)
      ),
      :count
    )
  end

  defp head_count(%ChangeRequest{id: id}) do
    Repo.one(
      from f in GitFacts, where: f.change_request_id == ^id, select: count(f.head, :distinct)
    )
  end

  @doc """
  Sets the parent of a `draft` or `open` change request to change request
  `number` of the same project, which must have a lower number, from a
  normalized body (`{"number": n}`), and recomputes the verdict. A child
  in another state is `{:coded_conflict, "not_editable", %{}}`; an
  unknown, equal or higher number is `{:invalid_body, %{"number" => _}}`.
  The parent row is locked (`FOR SHARE`) before the child's: `number`
  order, the same as a parent's state change, which locks its children
  after it, and the bulk recomputes.
  """
  @spec set_parent(ChangeRequest.t(), ApiKey.t(), term()) ::
          {:ok, ChangeRequest.t()}
          | {:error, {:invalid_body, map()} | {:coded_conflict, String.t(), map()}}
  def set_parent(%ChangeRequest{} = change_request, %ApiKey{} = api_key, body) do
    with :ok <- require_editable(change_request),
         {:ok, number} <- Params.parent(body),
         {:ok, parent} <- parent_by_number(change_request, number) do
      Repo.transaction(fn ->
        Repo.one!(from c in ChangeRequest, where: c.id == ^parent.id, lock: "FOR SHARE")
        relink(change_request, parent.id, api_key)
      end)
    end
  end

  @doc """
  Clears the parent of a `draft` or `open` change request and recomputes
  the verdict; another state is `{:coded_conflict, "not_editable", %{}}`.
  """
  @spec clear_parent(ChangeRequest.t(), ApiKey.t()) ::
          {:ok, ChangeRequest.t()} | {:error, {:coded_conflict, String.t(), map()}}
  def clear_parent(%ChangeRequest{} = change_request, %ApiKey{} = api_key) do
    with :ok <- require_editable(change_request) do
      Repo.transaction(fn -> relink(change_request, nil, api_key) end)
    end
  end

  defp relink(change_request, parent_id, api_key) do
    change_request = lock(change_request)
    if require_active(change_request) != :ok, do: Repo.rollback(not_editable())

    updated =
      change_request |> ChangeRequest.parent_changeset(parent_id) |> Repo.update!()

    if change_request.parent_id != parent_id do
      ProjectEvents.record(
        change_request.project_id,
        change_request.number,
        "cr_parent_changed",
        %{"from" => parent_number(change_request.parent_id), "to" => parent_number(parent_id)},
        Review.cli_actor(api_key)
      )
    end

    recompute(updated)
    updated
  end

  defp parent_number(nil), do: nil

  defp parent_number(parent_id),
    do: Repo.one!(from c in ChangeRequest, where: c.id == ^parent_id, select: c.number)

  defp parent_by_number(change_request, number) when number < change_request.number do
    case get(%Project{id: change_request.project_id}, number) do
      {:ok, parent} -> {:ok, parent}
      {:error, :not_found} -> number_error()
    end
  end

  defp parent_by_number(_change_request, _number), do: number_error()

  defp number_error,
    do:
      {:error,
       {:invalid_body,
        %{"number" => ["must be a lower change request number of the same project"]}}}

  defp require_editable(change_request) do
    if require_active(change_request) == :ok, do: :ok, else: {:error, not_editable()}
  end

  defp not_editable, do: {:coded_conflict, "not_editable", %{}}

  @doc """
  Changes the target branch of a `draft` or `open` change request from a
  normalized body (`{"target_branch": name}`) and recomputes its verdict in
  the same transaction; no Git ref and no head changes. With a parent,
  only after the parent is `merged` (else `{:coded_conflict,
  "parent_not_merged", %{}}`) and only to the parent's target branch (else
  `{:invalid_body, %{"target_branch" => _}}`); without one, any branch.
  A held merge lease is `{:coded_conflict, "lease_held", %{}}`, another
  state `not_editable`, and so is a parent link that changed under each
  of #{@retarget_attempts} attempts.
  """
  @spec retarget(ChangeRequest.t(), ApiKey.t(), term()) ::
          {:ok, ChangeRequest.t()}
          | {:error, {:invalid_body, map()} | {:coded_conflict, String.t(), map()}}
  def retarget(%ChangeRequest{} = change_request, %ApiKey{} = api_key, body) do
    with :ok <- require_editable(change_request),
         {:ok, target} <- Params.retarget(body) do
      retarget_attempt(change_request, target, api_key, @retarget_attempts)
    end
  end

  # The parent row is locked before the child's. When the parent link
  # changed between the read and the child's lock, the transaction rolls
  # back and restarts from a fresh read, so no parent is ever locked while
  # the child's lock is held. A link that changes under every attempt is
  # `not_editable`: the change request is being edited concurrently.
  defp retarget_attempt(change_request, target, api_key, attempts) do
    case Repo.transaction(fn -> retarget_locked(change_request, target, api_key) end) do
      {:error, :parent_moved} when attempts > 1 ->
        change_request = Repo.get!(ChangeRequest, change_request.id)
        retarget_attempt(change_request, target, api_key, attempts - 1)

      {:error, :parent_moved} ->
        {:error, not_editable()}

      result ->
        result
    end
  end

  defp retarget_locked(change_request, target, api_key) do
    parent = change_request.parent_id && lock_parent(change_request.parent_id)
    change_request = lock(change_request)

    cond do
      require_active(change_request) != :ok ->
        Repo.rollback(not_editable())

      change_request.parent_id != (parent && parent.id) ->
        Repo.rollback(:parent_moved)

      MergeLeases.held(change_request) != nil ->
        Repo.rollback({:coded_conflict, "lease_held", %{}})

      true ->
        check_parent_target(parent, target)

        updated =
          change_request |> ChangeRequest.target_changeset(target) |> Repo.update!()

        if change_request.target_branch != target do
          ProjectEvents.record(
            change_request.project_id,
            change_request.number,
            "cr_retargeted",
            %{"from" => change_request.target_branch, "to" => target},
            Review.cli_actor(api_key)
          )
        end

        recompute(updated)
        updated
    end
  end

  defp check_parent_target(nil, _target), do: :ok

  defp check_parent_target(%ChangeRequest{state: state}, _target) when state != "merged",
    do: Repo.rollback({:coded_conflict, "parent_not_merged", %{}})

  defp check_parent_target(%ChangeRequest{target_branch: target}, target), do: :ok

  defp check_parent_target(_parent, _target),
    do:
      Repo.rollback({:invalid_body, %{"target_branch" => ["must be the parent's target branch"]}})

  defp lock_parent(parent_id),
    do: Repo.one!(from c in ChangeRequest, where: c.id == ^parent_id, lock: "FOR SHARE")

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
    head_kind = head_kind(change_request, document)
    status = store_git_facts(change_request, api_key, document, head_kind)
    updated = put_head(change_request, document["head"])
    recompute(updated, nil, head_kind: if(status == :created, do: head_kind))
    {status, updated}
  end

  defp head_kind(%ChangeRequest{head: nil}, _document), do: "first"
  defp head_kind(%ChangeRequest{head: head}, %{"head" => head}), do: "retarget"

  defp head_kind(%ChangeRequest{head: previous} = change_request, document) do
    facts = previous_facts(change_request)

    cond do
      previous in Enum.map(document["commits"], & &1["sha"]) -> kind_keeping_head(facts, document)
      rebased?(facts, document) -> "rebase"
      true -> "rewrite"
    end
  end

  defp kind_keeping_head(nil = _no_merge_base_to_compare, _document), do: "fast_forward"

  defp kind_keeping_head(facts, document),
    do: if(same_merge_base?(facts, document), do: "fast_forward", else: "target_merged")

  defp rebased?(nil, _document), do: false

  defp rebased?(facts, document),
    do:
      not same_merge_base?(facts, document) and
        commit_paths(document) == commit_paths(facts.document)

  defp same_merge_base?(%GitFacts{document: stored}, document),
    do: stored["target"]["merge_base"] == document["target"]["merge_base"]

  defp previous_facts(%ChangeRequest{id: id, head: head, target_branch: target}) do
    Repo.one(
      from f in GitFacts,
        where: f.change_request_id == ^id and f.head == ^head,
        order_by: [desc: f.target_branch == ^target, desc: f.inserted_at],
        limit: 1
    )
  end

  defp commit_paths(document),
    do: Enum.map(document["commits"], fn c -> Enum.map(c["changed_files"], & &1["path"]) end)

  @doc """
  Locks the change request row (`FOR UPDATE`) inside the caller's
  transaction and returns it fresh, rolling back with `:not_active` when it
  is not `draft` or `open`.
  """
  @spec lock_active(ChangeRequest.t()) :: ChangeRequest.t()
  def lock_active(change_request) do
    change_request = lock(change_request)
    if require_active(change_request) != :ok, do: Repo.rollback(:not_active)
    change_request
  end

  @doc "`:ok` for a `draft` or `open` change request, else `{:error, :not_active}`."
  @spec require_active(ChangeRequest.t()) :: :ok | {:error, :not_active}
  def require_active(%ChangeRequest{state: state}) when state in @active_states, do: :ok
  def require_active(%ChangeRequest{}), do: {:error, :not_active}

  defp store_git_facts(change_request, api_key, document, head_kind) do
    digest = JsonDocument.digest(document)

    row = %{
      id: Ecto.UUID.generate(),
      change_request_id: change_request.id,
      head: document["head"],
      target_branch: document["target"]["branch"],
      document: document,
      digest: digest,
      previous_head: change_request.head,
      head_kind: head_kind,
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

  defp put_head(change_request, head) do
    Review.stale_open_tasks(change_request)
    change_request |> ChangeRequest.head_changeset(head) |> Repo.update!()
  end

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

  Option `head_kind:` is the kind of the Git facts row the caller just
  stored for a new head; it is recorded on a transition and on spans
  closed with cause `head`.
  """
  @spec recompute(ChangeRequest.t(), Rules.policy() | nil, keyword()) :: :ok | :skipped
  def recompute(change_request, policy \\ nil, opts \\ [])

  def recompute(%ChangeRequest{state: state} = change_request, policy, opts)
      when state in @active_states do
    policy = policy || ReviewPolicies.compiled(change_request.project_id)
    facts = current_facts(change_request)

    grading = Grading.load(change_request, facts && facts.document, policy)
    claims = facts && current_claims(change_request)

    verdict =
      Rules.evaluate(%{
        head: change_request.head,
        git_facts: facts && %{document: facts.document, digest: facts.digest},
        claims: claims,
        workflows: required_workflows(change_request, policy),
        policy: policy,
        grading: grading,
        parent: parent_input(change_request),
        merge_result: merge_result_input(change_request, facts, policy, grading)
      })

    items = Items.build(verdict.reasons, claims && claims.front_matter)

    {verdict_state, review} =
      Items.resolve(verdict.state, items, Review.current_answers(change_request))

    previous = Repo.get(Verdict, change_request.id)

    stored = %Verdict{
      change_request_id: change_request.id,
      state: verdict_state,
      head: verdict.head,
      policy_version: verdict.policy_version,
      reasons: verdict.reasons,
      inputs: verdict.inputs,
      scenarios: verdict.scenarios,
      coverage: verdict.coverage,
      counted_runs: verdict.counted_runs,
      review: review,
      computed_at: DateTime.utc_now()
    }

    Repo.insert!(stored,
      on_conflict: {:replace_all_except, [:change_request_id]},
      conflict_target: :change_request_id
    )

    record_counted_runs(change_request, grading.runs)
    record_verdict_changed(change_request, previous, stored)
    head_kind = Keyword.get(opts, :head_kind)
    record_transition(change_request, previous, stored, head_kind)
    record_spans(change_request, previous, stored, head_kind)
    :ok
  end

  def recompute(%ChangeRequest{}, _policy, _opts), do: :skipped

  defp parent_input(%ChangeRequest{parent_id: nil}), do: nil

  defp parent_input(%ChangeRequest{parent_id: parent_id}) do
    Repo.one(
      from c in ChangeRequest,
        where: c.id == ^parent_id,
        select: %{number: c.number, state: c.state}
    )
  end

  # The merge-result check applies while the change request holds a lease,
  # `merge.regrade_merge_result` is on, and the lease's base is not the
  # head's `git-facts` merge base.
  defp merge_result_input(_change_request, nil, _policy, _grading), do: nil

  defp merge_result_input(change_request, %GitFacts{document: document}, policy, grading) do
    with true <- policy.effective["merge"]["regrade_merge_result"],
         %Lease{base: base} <- MergeLeases.held(change_request),
         true <- base != document["target"]["merge_base"] do
      %{base: base, runs: Grading.merge_result_runs(change_request.project_id, base, grading)}
    else
      _other -> nil
    end
  end

  @verdict_changed_fields [
    :state,
    :head,
    :policy_version,
    :reasons,
    :scenarios,
    :coverage,
    :counted_runs,
    :review
  ]

  defp record_verdict_changed(change_request, previous, %Verdict{} = verdict) do
    if previous == nil or
         verdict_changed_fields_as_stored(previous) != verdict_changed_fields_as_stored(verdict) do
      ProjectEvents.record(
        change_request.project_id,
        change_request.number,
        "verdict_changed",
        %{
          "from" => previous && previous.state,
          "to" => verdict.state,
          "head" => verdict.head,
          "policy_version" => verdict.policy_version
        },
        nil
      )
    end

    :ok
  end

  defp record_transition(change_request, previous, %Verdict{} = verdict, head_kind) do
    if transition?(previous, verdict) do
      cause = cause(previous, verdict)

      Repo.insert!(%VerdictTransition{
        change_request_id: change_request.id,
        from_state: previous && previous.state,
        to_state: verdict.state,
        from_head: previous && previous.head,
        to_head: verdict.head,
        policy_version: verdict.policy_version,
        cause: cause,
        head_kind: if(cause == "head", do: head_kind),
        inserted_at: verdict.computed_at
      })
    end

    :ok
  end

  defp transition?(nil, _verdict), do: true

  defp transition?(previous, verdict),
    do: state_head_and_policy(previous) != state_head_and_policy(verdict)

  defp state_head_and_policy(%Verdict{} = verdict),
    do: {verdict.state, verdict.head, verdict.policy_version}

  defp cause(nil, _verdict), do: "created"
  defp cause(%Verdict{head: from}, %Verdict{head: to}) when from != to, do: "head"

  defp cause(%Verdict{policy_version: from}, %Verdict{policy_version: to}) when from != to,
    do: "policy"

  defp cause(_previous, _verdict), do: "inputs"

  defp record_spans(change_request, previous, %Verdict{} = verdict, head_kind) do
    open =
      Repo.all(
        from s in ReasonSpan,
          where: s.change_request_id == ^change_request.id and is_nil(s.closed_at)
      )

    keys = verdict.reasons |> Enum.map(&span_key/1) |> Enum.uniq()
    open_keys = MapSet.new(open, &{&1.rule, &1.subject, &1.outcome})
    gone = Enum.reject(open, &({&1.rule, &1.subject, &1.outcome} in keys))
    now = verdict.computed_at

    if gone != [] do
      cause = cause(previous, verdict)

      close_spans(
        Enum.map(gone, & &1.id),
        verdict.head,
        now,
        cause,
        if(cause == "head", do: head_kind)
      )
    end

    inherited = keys_from_before_spans(change_request, previous, open)

    rows =
      for {rule, subject, outcome} = key <- keys, not MapSet.member?(open_keys, key) do
        %{
          id: Ecto.UUID.generate(),
          change_request_id: change_request.id,
          rule: rule,
          subject: subject,
          outcome: outcome,
          opened_head: verdict.head,
          opened_policy_version: verdict.policy_version,
          opened_at: now,
          inherited: key in inherited
        }
      end

    if rows != [], do: Repo.insert_all(ReasonSpan, rows)
    :ok
  end

  defp span_key(%{"rule" => rule, "subject" => subject, "outcome" => outcome}),
    do: {rule, subject, outcome}

  defp keys_from_before_spans(_change_request, nil = _no_stored_verdict, _open), do: []
  defp keys_from_before_spans(_change_request, _previous, [_ | _] = _open), do: []

  defp keys_from_before_spans(change_request, %Verdict{reasons: reasons}, []) do
    if spans_ever_recorded?(change_request),
      do: [],
      else: Enum.map(reasons, &span_key/1)
  end

  defp spans_ever_recorded?(%ChangeRequest{id: id}),
    do: Repo.exists?(from s in ReasonSpan, where: s.change_request_id == ^id)

  defp close_open_spans(%ChangeRequest{id: id, head: head}, cause, at) do
    ids =
      Repo.all(
        from s in ReasonSpan,
          where: s.change_request_id == ^id and is_nil(s.closed_at),
          select: s.id
      )

    close_spans(ids, head, at, cause, nil)
  end

  defp close_spans([], _head, _at, _cause, _head_kind), do: :ok

  defp close_spans(ids, head, at, cause, head_kind) do
    Repo.update_all(from(s in ReasonSpan, where: s.id in ^ids),
      set: [closed_head: head, closed_at: at, close_cause: cause, close_head_kind: head_kind]
    )

    :ok
  end

  defp verdict_changed_fields_as_stored(%Verdict{} = verdict),
    do: verdict |> Map.take(@verdict_changed_fields) |> Jason.encode!() |> Jason.decode!()

  defp record_counted_runs(_change_request, []), do: :ok

  defp record_counted_runs(change_request, runs) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "verify_run_counts",
      Enum.map(runs, fn run ->
        %{
          change_request_id: Ecto.UUID.dump!(change_request.id),
          verify_run_id: Ecto.UUID.dump!(run.id),
          inserted_at: now
        }
      end),
      on_conflict: :nothing
    )

    :ok
  end

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

  @typedoc """
  The project event a stored run records for each change request it
  recomputes: its type, data and actor.
  """
  @type run_event :: {String.t(), map(), ApiKey.t() | nil}

  @doc """
  Recomputes every `draft` or `open` change request of the project whose
  head is `commit`, and records `run_event` for each. Called in the
  transaction that stores a workflow run.
  """
  @spec recompute_for_commit(Ecto.UUID.t(), String.t() | nil, run_event()) :: :ok
  def recompute_for_commit(_project_id, nil, _run_event), do: :ok

  def recompute_for_commit(project_id, commit, run_event) do
    lock_head(project_id, commit)

    change_requests =
      Repo.all(
        from c in ChangeRequest,
          where: c.project_id == ^project_id and c.head == ^commit and c.state in @active_states,
          order_by: c.number,
          lock: "FOR UPDATE"
      )

    if change_requests != [] do
      policy = ReviewPolicies.compiled(project_id)
      Enum.each(change_requests, &recompute(&1, policy))
      record_run_events(change_requests, run_event)
    end

    :ok
  end

  defp record_run_events(change_requests, {type, data, api_key}) do
    actor = api_key && Review.cli_actor(api_key)

    Enum.each(change_requests, &ProjectEvents.record(&1.project_id, &1.number, type, data, actor))
  end

  # Serializes a Git facts report that moves a head to `commit` with a
  # workflow run stored on `commit`. Without it, under READ COMMITTED, the
  # run's `recompute_for_commit/3` skips a change request whose head update
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
  Recomputes every `draft` or `open` change request of the project that
  has a scenario set version with `digest`, and records `run_event` for
  each. Called in the transaction that makes a verify run on that digest
  `final`, after `GoodFlows.ScenarioSets.lock_digest/2`.
  """
  @spec recompute_for_scenario_digest(Ecto.UUID.t(), String.t(), run_event()) :: :ok
  def recompute_for_scenario_digest(project_id, digest, run_event) do
    with_set =
      from v in GoodFlows.ScenarioSets.Version,
        where: v.project_id == ^project_id and v.digest == ^digest,
        select: v.change_request_id

    change_requests =
      Repo.all(
        from c in ChangeRequest,
          where:
            c.project_id == ^project_id and c.state in @active_states and
              c.id in subquery(with_set),
          order_by: c.number,
          lock: "FOR UPDATE"
      )

    if change_requests != [] do
      policy = ReviewPolicies.compiled(project_id)
      Enum.each(change_requests, &recompute(&1, policy))
      record_run_events(change_requests, run_event)
    end

    :ok
  end

  @doc """
  After a new policy or feature index version: recomputes every `draft` and `open` change
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
              order_by: c.number,
              lock: "FOR UPDATE"
          )

        policy = ReviewPolicies.compiled(project_id)
        Enum.each(change_requests, &recompute(&1, policy))
        length(change_requests)
      end)

    count
  end
end
