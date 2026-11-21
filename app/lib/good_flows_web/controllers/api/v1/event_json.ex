defmodule GoodFlowsWeb.Api.V1.EventJSON do
  @moduledoc """
  Renders project events. Public keys (`redact?: true`) see `actor` null
  and `note` null in `scenario_set_rejected`, `answer_recorded`,
  `task_created` and `policy_version_created` events; a field absent from
  an event is never added, and stored rows do not change.
  """

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.ProjectEvents.Event

  @noted ~w(scenario_set_rejected answer_recorded task_created policy_version_created)

  @doc "Renders one page of events."
  def index(%{events: events, next_cursor: next_cursor, redact?: redact?}) do
    %{data: Enum.map(events, &event(&1, redact?)), next_cursor: next_cursor}
  end

  defp event(%Event{} = event, redact?) do
    %{
      id: event.id,
      type: event.type,
      number: event.change_request_number,
      data: data(event, redact?),
      actor: actor(event, redact?),
      inserted_at: DateTime.to_iso8601(event.inserted_at)
    }
  end

  defp data(%Event{type: type, data: %{"note" => _note} = data}, true) when type in @noted,
    do: %{data | "note" => nil}

  defp data(%Event{data: data}, _redact?), do: data

  defp actor(_event, true), do: nil
  defp actor(%Event{actor_membership_id: nil, actor_key_id: nil}, false), do: nil

  defp actor(%Event{} = event, false) do
    user_id =
      case event.actor_membership do
        %AccountUser{user_id: id} -> id
        _other -> nil
      end

    %{user_id: user_id, key_id: event.actor_key_id}
  end
end
