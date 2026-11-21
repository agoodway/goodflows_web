defmodule GoodFlowsWeb.Api.V1.ScenarioSetJSON do
  @moduledoc """
  Renders scenario set versions, decisions and comparisons.

  Public keys (`redact?: true`) see `content`, `front_matter` and
  `sections` as null; `source`, `version`, `digest`, `inserted_at`,
  `approved` and each scenario's `id` and `priority` (`scenarios`) are as
  stored. Decisions show `note` and `decided_by.user_id` as null.
  """

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.ScenarioSets.{Decision, Version}

  @doc "Renders one version, with its decisions when given."
  def show(%{version: version, approved: approved, redact?: redact?} = assigns) do
    data =
      version
      |> version(approved, redact?)
      |> put_present(
        :decisions,
        assigns[:decisions] && Enum.map(assigns.decisions, &decision(&1, redact?))
      )
      |> put_present(:duplicate, assigns[:duplicate])

    %{data: data}
  end

  @doc "Renders the intent and diff sets of a change request."
  def index(%{sets: sets, redact?: redact?}) do
    data =
      Map.new(sets, fn {source, listed} ->
        current =
          case listed do
            [%{version: v, approved: a} | _rest] -> version(v, a, redact?)
            [] -> nil
          end

        {source,
         %{
           current: current,
           versions:
             Enum.map(listed, fn %{version: v, approved: a} ->
               %{
                 version: v.version,
                 digest: v.digest,
                 inserted_at: DateTime.to_iso8601(v.inserted_at),
                 approved: a
               }
             end)
         }}
      end)

    %{data: data}
  end

  @doc "Renders one decision."
  def decision(%{decision: decision, redact?: redact?}), do: %{data: decision(decision, redact?)}

  @doc "Renders a comparison."
  def compare(%{source: source, comparison: comparison}) do
    %{
      data: %{
        source: source,
        from: comparison.from && comparison.from.version,
        to: comparison.to.version,
        changes: comparison.changes
      }
    }
  end

  defp version(%Version{} = version, approved, redact?) do
    %{
      source: version.source,
      version: version.version,
      digest: version.digest,
      approved: approved,
      inserted_at: DateTime.to_iso8601(version.inserted_at),
      scenarios: Version.scenarios(version),
      content: if(redact?, do: nil, else: version.content),
      front_matter: if(redact?, do: nil, else: version.front_matter),
      sections: if(redact?, do: nil, else: version.sections)
    }
  end

  defp decision(%Decision{} = decision, redact?) do
    %{
      decision: decision.decision,
      digest: decision.digest,
      note: if(redact?, do: nil, else: decision.note),
      decided_by: %{user_id: user_id(decision.account_user, redact?)},
      decided_at: DateTime.to_iso8601(decision.inserted_at),
      channel: decision.channel
    }
  end

  defp user_id(%AccountUser{user_id: id}, false), do: id
  defp user_id(_account_user, _redact?), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
