defmodule GoodFlowsWeb.Api.V1.ReviewJSON do
  @moduledoc "Renders review packets, answers and tasks (private keys only)."

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.Review.{Answer, Task}

  @doc "Renders a review packet."
  def packet(%{packet: packet}) do
    items =
      Enum.map(packet.items, fn item ->
        %{item | answer: item.answer && answer_data(item.answer)}
      end)

    %{data: %{packet | items: items}}
  end

  @doc "Renders one stored answer."
  def answer(%{answer: %Answer{} = answer}), do: %{data: answer_data(answer)}

  @doc "Renders tasks."
  def tasks(%{tasks: tasks, number: number}),
    do: %{data: Enum.map(tasks, &task_data(&1, number))}

  @doc "Renders one task."
  def task(%{task: task, number: number}), do: %{data: task_data(task, number)}

  defp answer_data(%Answer{} = answer) do
    %{
      id: answer.id,
      item_id: answer.item_id,
      kind: answer.kind,
      rule: answer.rule,
      head: answer.head,
      answer: answer.answer,
      option: answer.option,
      note: answer.note,
      channel: answer.channel,
      answered_by: %{user_id: user_id(answer.account_user), key_id: answer.api_key_id},
      inserted_at: DateTime.to_iso8601(answer.inserted_at)
    }
  end

  defp task_data(%Task{} = task, number) do
    %{
      id: task.id,
      number: number,
      item_id: task.item_id,
      kind: task.kind,
      answer: task.answer,
      note: task.note,
      head: task.head,
      state: task.state,
      created_by: %{user_id: user_id(task.created_by_account_user)},
      created_at: DateTime.to_iso8601(task.inserted_at),
      done_by: task.done_at && %{user_id: user_id(task.done_by_account_user)},
      done_at: task.done_at && DateTime.to_iso8601(task.done_at)
    }
  end

  defp user_id(%AccountUser{user_id: id}), do: id
  defp user_id(_account_user), do: nil
end
