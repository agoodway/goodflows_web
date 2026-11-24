defmodule GoodFlows.Review do
  @moduledoc """
  Review of change requests (the `change-request-review` capability): the
  review packet at the current head, answers bound to that head, and the
  tasks that `request_change` and `reject` answers create.

  `packet/1` reads the stored verdict and turns its reasons into items
  (`GoodFlows.Review.Items`) with the data a reviewer needs for each kind
  (`GoodFlows.Review.Packet`).

  `answer/4` stores an answer in one transaction: it checks the change
  request is `draft` or `open` (`:not_active`) before anything else, then
  the body, then (under the change request's row lock) that `head` is the
  current head (`{:stale_head, head}`), that the item exists at the head
  (`:not_found`), that the answer and option suit the item, and, for
  `scenario_set_approval` and `diff_set_weakened`, the policy's
  `scenarios.approver` (`:forbidden`). It replaces the item's earlier
  answer at the head (whose `open` task becomes `stale`), records an
  `approve` or `reject` decision on the set digest for a
  `scenario_set_approval` item, creates a task for `request_change` and
  `reject`, records `answer_recorded` (and `task_created`) and recomputes
  the verdict. The answer's actor (`t:actor/0`) is a membership, the key
  it used (nil in the dashboard) and the channel (`cli` or `dashboard`);
  the answer, its decisions, its task and its events record that actor.

  A `diff_set_weakened` answer acts on the stored verdict's diff digest
  after it is stored: `reject` records a `reject` decision with its note,
  and `approve` records an `approve` decision, with this answer's
  actor, once every `diff_set_weakened` item of the stored
  verdict has a current `approve`. The accepted digest becomes the diff
  baseline, so the recompute drops those reasons. Storing a diff version
  supersedes every `diff_set_weakened` answer
  (`supersede_diff_answers/1`), so they count only while the diff digest
  they were given on is current.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.{ChangeRequest, Params, Verdict}
  alias GoodFlows.DocumentErrors
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Repo
  alias GoodFlows.Review.{Answer, Items, Packet, Task}
  alias GoodFlows.ScenarioSets
  alias GoodFlows.TestReports.Shape

  @answers ~w(approve reject request_change choose)
  @max_note_bytes 10_000
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @typedoc """
  Who acts: the membership, the key it used (nil for a signed-in member
  in the dashboard) and the channel. It is the actor of answers, scenario
  set decisions and project events (`GoodFlows.ProjectEvents.record/5`).
  """
  @type actor :: %{
          account_user: AccountUser.t(),
          api_key: ApiKey.t() | nil,
          channel: String.t()
        }

  @doc "The actor of an API request made with `api_key` by `account_user`."
  @spec cli_actor(AccountUser.t(), ApiKey.t()) :: actor()
  def cli_actor(%AccountUser{} = account_user, %ApiKey{} = api_key),
    do: %{account_user: account_user, api_key: api_key, channel: "cli"}

  @doc """
  The actor of an API request made with `api_key` by the key's own
  membership, which is loaded when the key does not carry it.
  """
  @spec cli_actor(ApiKey.t()) :: actor()
  def cli_actor(%ApiKey{} = api_key) do
    %ApiKey{account_user: %AccountUser{} = account_user} =
      api_key = Repo.preload(api_key, :account_user)

    cli_actor(account_user, api_key)
  end

  @doc "The actor of a signed-in member answering in the dashboard."
  @spec dashboard_actor(AccountUser.t()) :: actor()
  def dashboard_actor(%AccountUser{} = account_user),
    do: %{account_user: account_user, api_key: nil, channel: "dashboard"}

  @doc """
  The review packet at the change request's current head. It reloads the
  change request `FOR SHARE` and builds the packet under that lock: every
  write a packet reads (Git facts, claims, answers, scenario sets, verdict
  recomputes) locks the row `FOR UPDATE` first, so the head and its inputs
  cannot change mid-read.
  """
  @spec packet(ChangeRequest.t()) :: Packet.t()
  def packet(%ChangeRequest{id: id}) do
    {:ok, packet} =
      Repo.transaction(fn ->
        change_request =
          Repo.one!(from c in ChangeRequest, where: c.id == ^id, lock: "FOR SHARE")

        verdict = Repo.get!(Verdict, id)
        Packet.build(change_request, verdict, current_answer_rows(change_request))
      end)

    packet
  end

  @doc """
  The current answers at the change request's head (nil included), as
  `%{item_id => answer}`.
  """
  @spec current_answers(ChangeRequest.t()) :: %{String.t() => String.t()}
  def current_answers(%ChangeRequest{} = change_request) do
    change_request
    |> current_query()
    |> select([a], {a.item_id, a.answer})
    |> Repo.all()
    |> Map.new()
  end

  defp current_answer_rows(change_request) do
    change_request
    |> current_query()
    |> preload(:account_user)
    |> Repo.all()
    |> Map.new(&{&1.item_id, &1})
  end

  defp current_query(%ChangeRequest{id: id, head: nil}),
    do:
      from(a in Answer,
        where: a.change_request_id == ^id and is_nil(a.superseded_at) and is_nil(a.head)
      )

  defp current_query(%ChangeRequest{id: id, head: head}),
    do:
      from(a in Answer,
        where: a.change_request_id == ^id and is_nil(a.superseded_at) and a.head == ^head
      )

  @doc """
  Stores an answer to item `item_id` from a normalized body (see the
  module documentation). Returns `{:ok, answer}` or `{:error, reason}`.
  """
  @spec answer(ChangeRequest.t(), actor(), String.t(), term()) ::
          {:ok, Answer.t()}
          | {:error,
             :not_active
             | :not_found
             | :forbidden
             | :stale_digest
             | {:stale_head, String.t() | nil}
             | {:invalid_body, DocumentErrors.errors()}}
  def answer(
        %ChangeRequest{} = change_request,
        %{account_user: %AccountUser{}, channel: channel} = actor,
        item_id,
        body
      )
      when channel in ~w(cli dashboard) do
    with :ok <- ChangeRequests.require_active(change_request),
         {:ok, attrs} <- answer_body(body) do
      Repo.transaction(fn ->
        change_request = ChangeRequests.lock_active(change_request)
        answer_locked(change_request, actor, item_id, attrs)
      end)
      |> case do
        {:ok, answer} -> {:ok, Repo.preload(answer, :account_user)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A `reject` or `request_change` note must not be only whitespace, as
  # for the scenario set rejection body.
  defp answer_body(body) do
    non_blank = is_map(body) and body["answer"] in ~w(reject request_change)

    spec =
      {:object,
       %{
         "head" => {:nullable, Params.sha_spec()},
         "answer" => {:enum, @answers},
         "option" => {:optional, {:string, min: 1, max: 1_024}},
         "note" =>
           {:optional, {:nullable, {:string, min: 1, max: @max_note_bytes, non_blank: non_blank}}}
       }}

    errors =
      case Shape.check(body, spec, []) do
        [] -> cross_errors(body)
        errors -> errors
      end

    if errors == [] do
      {:ok,
       %{
         head: body["head"],
         answer: body["answer"],
         option: body["option"],
         note: body["note"]
       }}
    else
      {:error, {:invalid_body, DocumentErrors.render(errors)}}
    end
  end

  defp cross_errors(%{"answer" => answer} = body) do
    option =
      cond do
        answer == "choose" and not Map.has_key?(body, "option") ->
          [{["option"], "is required for choose"}]

        answer != "choose" and Map.has_key?(body, "option") ->
          [{["option"], "is allowed only for choose"}]

        true ->
          []
      end

    note =
      if answer in ~w(reject request_change) and body["note"] == nil,
        do: [{["note"], "is required for #{answer}"}],
        else: []

    option ++ note
  end

  defp answer_locked(change_request, actor, item_id, attrs) do
    if attrs.head != change_request.head, do: Repo.rollback({:stale_head, change_request.head})

    verdict = Repo.get!(Verdict, change_request.id)
    claims = Packet.claims(change_request)
    item = Enum.find(Items.build(verdict.reasons, claims), &(&1.id == item_id))

    if item == nil, do: Repo.rollback(:not_found)
    check_item_answer(item, attrs, claims)

    if item.kind in ~w(scenario_set_approval diff_set_weakened) do
      with {:error, reason} <- ScenarioSets.check_approver(change_request, actor.account_user),
           do: Repo.rollback(reason)
    end

    if item.kind == "scenario_set_approval" do
      [digest] = item.subject

      ScenarioSets.record_decision(change_request, actor, %{
        decision: attrs.answer,
        digest: digest,
        note: attrs.note
      })
    end

    now = DateTime.utc_now()
    supersede(change_request, item.id, attrs.head, now)

    answer =
      Repo.insert!(%Answer{
        change_request_id: change_request.id,
        item_id: item.id,
        kind: item.kind,
        rule: item.rule,
        head: attrs.head,
        answer: attrs.answer,
        option: attrs.option,
        note: attrs.note,
        channel: actor.channel,
        account_user_id: actor.account_user.id,
        api_key_id: actor.api_key && actor.api_key.id
      })

    if item.kind == "diff_set_weakened",
      do: record_diff_decision(change_request, verdict, claims, actor, answer)

    ChangeRequests.recompute(change_request)

    ProjectEvents.record(
      change_request.project_id,
      change_request.number,
      "answer_recorded",
      %{
        "item_id" => answer.item_id,
        "kind" => answer.kind,
        "head" => answer.head,
        "answer" => answer.answer,
        "option" => answer.option,
        "note" => answer.note
      },
      actor
    )

    if answer.answer in ~w(reject request_change),
      do: create_task(change_request, answer, actor)

    answer
  end

  defp record_diff_decision(change_request, verdict, claims, actor, answer) do
    digest = verdict.scenarios["diff"]["digest"]

    decision =
      case answer.answer do
        "reject" ->
          %{decision: "reject", digest: digest, note: answer.note}

        "approve" ->
          answers = current_answers(change_request)

          if verdict.reasons
             |> Items.build(claims)
             |> Enum.filter(&(&1.kind == "diff_set_weakened"))
             |> Enum.all?(&(Map.get(answers, &1.id) == "approve")),
             do: %{decision: "approve", digest: digest, note: nil}
      end

    if decision,
      do: ScenarioSets.record_decision(change_request, actor, decision, "diff")

    :ok
  end

  defp check_item_answer(item, attrs, claims) do
    if attrs.answer not in item.answers,
      do: Repo.rollback({:invalid_body, %{"answer" => ["is not allowed for this item"]}})

    if attrs.answer == "choose" do
      [question_id] = item.subject
      question = Enum.find(claims["questions"], &(&1["id"] == question_id))

      if attrs.option not in question["options"],
        do:
          Repo.rollback({:invalid_body, %{"option" => ["must be one of the question's options"]}})
    end

    :ok
  end

  defp supersede(change_request, item_id, head, now) do
    earlier =
      from a in Answer,
        where:
          a.change_request_id == ^change_request.id and a.item_id == ^item_id and
            is_nil(a.superseded_at),
        select: a.id

    earlier =
      if head == nil,
        do: where(earlier, [a], is_nil(a.head)),
        else: where(earlier, [a], a.head == ^head)

    {_count, ids} = Repo.update_all(earlier, set: [superseded_at: now, updated_at: now])
    stale_tasks(ids, now)
  end

  defp stale_tasks([], _now), do: :ok

  defp stale_tasks(answer_ids, now) do
    Repo.update_all(
      from(t in Task, where: t.answer_id in ^answer_ids and t.state == "open"),
      set: [state: "stale", updated_at: now]
    )

    :ok
  end

  defp create_task(change_request, answer, actor) do
    task =
      Repo.insert!(%Task{
        change_request_id: change_request.id,
        answer_id: answer.id,
        item_id: answer.item_id,
        kind: answer.kind,
        answer: answer.answer,
        note: answer.note,
        head: answer.head,
        state: "open",
        created_by_account_user_id: answer.account_user_id
      })

    ProjectEvents.record(
      change_request.project_id,
      change_request.number,
      "task_created",
      %{
        "task_id" => task.id,
        "item_id" => task.item_id,
        "head" => task.head,
        "note" => task.note
      },
      actor
    )

    task
  end

  @doc """
  Supersedes every current `diff_set_weakened` answer of the change
  request, at every head, and makes their `open` tasks `stale`. Called in
  the transaction that stores a diff version, before its recompute, so an
  answer given on one diff digest never counts for another.
  """
  @spec supersede_diff_answers(ChangeRequest.t()) :: :ok
  def supersede_diff_answers(%ChangeRequest{id: id}) do
    now = DateTime.utc_now()

    {_count, ids} =
      Repo.update_all(
        from(a in Answer,
          where:
            a.change_request_id == ^id and a.kind == "diff_set_weakened" and
              is_nil(a.superseded_at),
          select: a.id
        ),
        set: [superseded_at: now, updated_at: now]
      )

    stale_tasks(ids, now)
  end

  @doc """
  Makes every `open` task of the change request `stale`. Called in the
  `git-facts` transaction that sets a new head; each task keeps its head.
  """
  @spec stale_open_tasks(ChangeRequest.t()) :: :ok
  def stale_open_tasks(%ChangeRequest{id: id}) do
    Repo.update_all(
      from(t in Task, where: t.change_request_id == ^id and t.state == "open"),
      set: [state: "stale", updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  The change request's tasks oldest first. Param `"state"` (`open`,
  `stale` or `done`) filters; without it, `open` and `stale` tasks.
  """
  @spec list_tasks(ChangeRequest.t(), map()) :: {:ok, [Task.t()]} | {:error, Ecto.Changeset.t()}
  def list_tasks(%ChangeRequest{id: id}, params) do
    with {:ok, %{state: state}} <- task_params(params) do
      states = if state, do: [state], else: ~w(open stale)

      {:ok,
       Repo.all(
         from t in Task,
           where: t.change_request_id == ^id and t.state in ^states,
           order_by: [asc: t.inserted_at, asc: t.id],
           preload: [:created_by_account_user, :done_by_account_user]
       )}
    end
  end

  defp task_params(params) do
    {%{state: nil}, %{state: :string}}
    |> Ecto.Changeset.cast(params, [:state], empty_values: [])
    |> Ecto.Changeset.validate_inclusion(:state, Task.states())
    |> Ecto.Changeset.apply_action(:list)
  end

  @doc """
  Marks task `task_id` of the change request `done` by `account_user`
  with `api_key`, recording `task_completed` with them as the actor. A
  `done` task is returned unchanged and records nothing; an unknown one is
  `:not_found`.
  """
  @spec complete_task(ChangeRequest.t(), AccountUser.t(), ApiKey.t(), String.t()) ::
          {:ok, Task.t()} | {:error, :not_found}
  def complete_task(
        %ChangeRequest{} = change_request,
        %AccountUser{} = account_user,
        %ApiKey{} = api_key,
        task_id
      ) do
    if is_binary(task_id) and Regex.match?(@uuid, task_id) do
      Repo.transaction(fn -> complete_locked(change_request, account_user, api_key, task_id) end)
      |> case do
        {:ok, task} ->
          {:ok,
           Repo.preload(task, [:created_by_account_user, :done_by_account_user], force: true)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp complete_locked(change_request, account_user, api_key, task_id) do
    Repo.one!(from c in ChangeRequest, where: c.id == ^change_request.id, lock: "FOR UPDATE")

    task =
      Repo.one(
        from t in Task,
          where: t.change_request_id == ^change_request.id and t.id == ^task_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:not_found)

    if task.state == "done" do
      task
    else
      task =
        task
        |> Ecto.Changeset.change(
          state: "done",
          done_by_account_user_id: account_user.id,
          done_at: DateTime.utc_now()
        )
        |> Repo.update!()

      ProjectEvents.record(
        change_request.project_id,
        change_request.number,
        "task_completed",
        %{"task_id" => task.id, "item_id" => task.item_id},
        cli_actor(account_user, api_key)
      )

      task
    end
  end
end
