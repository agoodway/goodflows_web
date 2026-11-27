defmodule GoodFlowsWeb.Api.V1.StoredChangeJSON do
  @moduledoc """
  Renders stored changes and their versions. Public keys (`redact?:
  true`) see `pushed_by` null and, in the versions list, only the
  version number, status, `pushed_at`, `source` and `latest`; they never
  reach a render with files.
  """

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.StoredChanges.{Change, Version}

  @public_version_fields [:version, :status, :pushed_at, :source, :pushed_by]

  @doc "Renders a push result."
  def push(%{version: %Version{} = version, duplicate: duplicate, replaced: replaced}) do
    %{
      data:
        version
        |> data(false)
        |> Map.merge(%{duplicate: duplicate, replaced_version: replaced})
    }
  end

  @doc "Renders one page of stored changes."
  def index(%{changes: changes, change_requests: links, next_cursor: next_cursor}) do
    %{
      data:
        Enum.map(changes, fn change ->
          change |> listed() |> Map.put(:change_requests, Map.get(links, change.change_id, []))
        end),
      next_cursor: next_cursor
    }
  end

  @doc "Renders a change's latest version with its files and linked change requests."
  def show(%{version: %Version{} = version, change_requests: change_requests}) do
    %{
      data:
        version
        |> data(false)
        |> Map.merge(%{files: files(version), change_requests: change_requests})
    }
  end

  @doc "Renders one page of versions."
  def versions(%{versions: versions, next_cursor: next_cursor, redact?: redact?}) do
    %{
      data:
        Enum.map(versions, fn version ->
          version
          |> data(redact?)
          |> then(&if redact?, do: Map.take(&1, @public_version_fields), else: &1)
          |> Map.put(:latest, version.version == version.stored_change.latest_version)
        end),
      next_cursor: next_cursor
    }
  end

  @doc "Renders one version with its files and the change's latest status."
  def show_version(%{version: %Version{} = version}) do
    %{
      data:
        version
        |> data(false)
        |> Map.merge(%{files: files(version), latest_status: version.stored_change.status})
    }
  end

  defp listed(%Change{} = change) do
    %{
      change_id: change.change_id,
      version: change.latest_version,
      status: change.status,
      size: change.size,
      door: change.door,
      capabilities: change.capabilities,
      depends_on: change.depends_on,
      last_pushed_at: DateTime.to_iso8601(change.last_pushed_at)
    }
  end

  defp data(%Version{} = version, redact?) do
    %{
      change_id: version.stored_change.change_id,
      version: version.version,
      status: version.status,
      size: version.size,
      door: version.door,
      capabilities: version.capabilities,
      depends_on: version.depends_on,
      pushed_at: DateTime.to_iso8601(version.inserted_at),
      source: %{commit: version.commit, branch: version.branch, dirty: version.dirty},
      pushed_by: pushed_by(version.account_user, redact?)
    }
  end

  defp pushed_by(_account_user, true), do: nil
  defp pushed_by(%AccountUser{user_id: id}, false), do: %{user_id: id}
  defp pushed_by(_account_user, false), do: %{user_id: nil}

  defp files(%Version{files: files}) do
    files |> Enum.sort() |> Enum.map(fn {path, text} -> %{path: path, text: text} end)
  end
end
