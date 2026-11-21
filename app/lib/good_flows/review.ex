defmodule GoodFlows.Review do
  @moduledoc """
  Review of change requests (the `change-request-review` capability): the
  review packet at the current head, answers bound to that head, and the
  tasks that `request_change` and `reject` answers create.

  `packet/1` reads the stored verdict and turns its reasons into items
  (`GoodFlows.Review.Items`) with the data a reviewer needs for each kind
  (`GoodFlows.Review.Packet`).

  `answer/5` stores an answer in one transaction: it checks the change
  request is `draft` or `open` (`:not_active`) before anything else, then
  the body, then (under the change request's row lock) that `head` is the
  current head (`{:stale_head, head}`), that the item exists at the head
  (`:not_found`), that the answer and option suit the item, and, for
  `scenario_set_approval`, the policy's `scenarios.approver`
  (`:forbidden`). It replaces the item's earlier answer at the head (whose
  `open` task becomes `stale`), records an `approve` or `reject` decision
  on the set digest for a `scenario_set_approval` item, creates a task for
  `request_change` and `reject`, records `answer_recorded` (and
  `task_created`) and recomputes the verdict.
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
  @spec answer(ChangeRequest.t(), AccountUser.t(), ApiKey.t(), String.t(), term()) ::
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
        %AccountUser{} = account_user,
        api_key,
        item_id,
        body
      ) do
    with :ok <- ChangeRequests.require_active(change_request),
         {:ok, attrs} <- answer_body(body) do
      Repo.transaction(fn ->
        change_request = ChangeRequests.lock_active(change_request)
        answer_locked(change_request, account_user, api_key, item_id, attrs)
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

  defp answer_locked(change_request, account_user, api_key, item_id, attrs) do
    if attrs.head != change_request.head, do: Repo.rollback({:stale_head, change_request.head})

    verdict = Repo.get!(Verdict, change_request.id)
    claims = Packet.claims(change_request)
    item = Enum.find(Items.build(verdict.reasons, claims), &(&1.id == item_id))

    if item == nil, do: Repo.rollback(:not_found)
    check_item_answer(item, attrs, claims)

    if item.kind == "scenario_set_approval" do
      with {:error, reason} <- ScenarioSets.check_approver(change_request, account_user),
           do: Repo.rollback(reason)

      [digest] = item.subject

      ScenarioSets.record_decision(change_request, account_user, api_key, %{
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
        channel: "cli",
        account_user_id: account_user.id,
        api_key_id: api_key.id
      })

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
      api_key
    )

    if answer.answer in ~w(reject request_change),
      do: create_task(change_request, answer, api_key)

    answer
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

    if ids != [] do
      Repo.update_all(
        from(t in Task, where: t.answer_id in ^ids and t.state == "open"),
        set: [state: "stale", updated_at: now]
      )
    end

    :ok
  end

  defp create_task(change_request, answer, api_key) do
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
      api_key
    )

    task
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
  Marks task `task_id` of the change request `done` by `account_user`. A
  `done` task is returned unchanged; an unknown one is `:not_found`.
  """
  @spec complete_task(ChangeRequest.t(), AccountUser.t(), String.t()) ::
          {:ok, Task.t()} | {:error, :not_found}
  def complete_task(%ChangeRequest{id: id}, %AccountUser{} = account_user, task_id) do
    if is_binary(task_id) and Regex.match?(@uuid, task_id) do
      Repo.transaction(fn -> complete_locked(id, account_user, task_id) end)
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

  defp complete_locked(change_request_id, account_user, task_id) do
    task =
      Repo.one(
        from t in Task,
          where: t.change_request_id == ^change_request_id and t.id == ^task_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:not_found)

    if task.state == "done" do
      task
    else
      task
      |> Ecto.Changeset.change(
        state: "done",
        done_by_account_user_id: account_user.id,
        done_at: DateTime.utc_now()
      )
      |> Repo.update!()
    end
  end
end
