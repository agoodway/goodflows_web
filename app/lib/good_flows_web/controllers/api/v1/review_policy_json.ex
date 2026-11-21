defmodule GoodFlowsWeb.Api.V1.ReviewPolicyJSON do
  @moduledoc """
  Renders review policy versions. Every version carries the policy as
  written, the `effective` document, and `active_settings`. Public keys
  (`redact?: true`) see `note` and `written_by` as null. Version 0 has
  `written_by`, `note` and `inserted_at` null.
  """

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.ReviewPolicies.{Document, Version}

  @doc "Renders one version."
  def show(%{version: version, redact?: redact?}), do: %{data: data(version, redact?)}

  @doc "Renders one page of versions."
  def index(%{versions: versions, next_cursor: next_cursor, redact?: redact?}) do
    %{data: Enum.map(versions, &data(&1, redact?)), next_cursor: next_cursor}
  end

  defp data(%Version{} = version, redact?) do
    %{
      version: version.version,
      previous_version: version.previous_version,
      policy: version.document,
      effective: Document.effective(version.document),
      note: if(redact?, do: nil, else: version.note),
      written_by: written_by(version, redact?),
      inserted_at: version.inserted_at && DateTime.to_iso8601(version.inserted_at),
      active_settings: Document.active_settings()
    }
  end

  defp written_by(%Version{version: 0}, _redact?), do: nil
  defp written_by(%Version{}, true), do: nil
  defp written_by(%Version{account_user: %AccountUser{user_id: id}}, false), do: %{user_id: id}
  defp written_by(%Version{}, false), do: %{user_id: nil}
end
