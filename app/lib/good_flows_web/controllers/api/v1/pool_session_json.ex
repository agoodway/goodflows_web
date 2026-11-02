defmodule GoodFlowsWeb.Api.V1.PoolSessionJSON do
  @moduledoc """
  Renders pool sessions. Never includes the owner id, credential
  fingerprint, workspace contents, commands, environment values, or output.
  """

  alias GoodFlows.Pools.{Events, Member, Session}

  @doc "Renders one session with its currently granted members."
  def show(%{session: %Session{} = session, members: members}) do
    %{
      data: %{
        id: session.id,
        status: session.status,
        end_reason: if(session.status == "expired", do: session.end_reason),
        pool: session.pool_slug,
        project: session.project_slug,
        max_members: session.max_members,
        wanted: session.wanted,
        label: session.label,
        topic: Events.session_topic(session.id),
        members: Enum.map(members, &member/1),
        workspace_uploaded: session.workspace_uploaded_at != nil,
        acquire_deadline_at: session.acquire_deadline_at,
        ended_at: session.ended_at,
        inserted_at: session.inserted_at,
        updated_at: session.updated_at
      }
    }
  end

  defp member(%Member{} = member),
    do: %{id: member.id, name: member.name, ready: Member.ready?(member)}
end
