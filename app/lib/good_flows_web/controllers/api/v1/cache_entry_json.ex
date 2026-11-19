defmodule GoodFlowsWeb.Api.V1.CacheEntryJSON do
  @moduledoc """
  Renders cache entries, reservations, lists and purge counts. Presigned
  URLs appear only in hit and reservation bodies.
  """

  alias GoodFlows.Caches.Entry

  @doc "Renders a lookup or commit hit with its download URL."
  def hit(%{entry: entry, download: download}) do
    %{
      data:
        entry
        |> data()
        |> Map.merge(%{download_url: download.url, download_url_expires_at: download.expires_at})
    }
  end

  @doc "Renders a reservation and its presigned upload."
  def reservation(%{reservation: reservation}) do
    %{
      data: %{
        upload_id: reservation.entry.id,
        upload_url: reservation.upload_url,
        upload_headers: reservation.upload_headers,
        upload_url_expires_at: reservation.upload_url_expires_at,
        expires_at: reservation.entry.expires_at
      }
    }
  end

  @doc "Renders a page of entries and the project's usage."
  def index(%{page: page}) do
    %{data: Enum.map(page.entries, &data/1), next_cursor: page.next_cursor, usage: page.usage}
  end

  @doc "Renders a purge count."
  def purge(%{deleted: deleted}), do: %{data: %{deleted: deleted}}

  defp data(%Entry{} = entry) do
    entry
    |> Map.take([:key, :partial, :name, :scope, :size, :sha256])
    |> Map.put(:created_at, entry.committed_at)
  end
end
