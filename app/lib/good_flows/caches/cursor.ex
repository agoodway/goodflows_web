defmodule GoodFlows.Caches.Cursor do
  @moduledoc """
  Keyset cursors for cache lists: the URL-safe base64 of
  `<ISO 8601 timestamp>|<lowercase uuid>`, the position of the last row of
  a page ordered by that timestamp and id, both descending.
  """

  alias GoodFlows.WorkflowRuns.Validator

  @doc "Encodes the position of a row."
  @spec encode(DateTime.t(), String.t()) :: String.t()
  def encode(%DateTime{} = at, id),
    do: Base.url_encode64("#{DateTime.to_iso8601(at)}|#{id}", padding: false)

  @doc "Decodes a cursor; anything that `encode/2` could not have produced is `:error`."
  @spec decode(String.t()) :: {:ok, {DateTime.t(), String.t()}} | :error
  def decode(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [timestamp, id] <- String.split(decoded, "|", parts: 2),
         true <- Validator.canonical_uuid?(id),
         {:ok, at, 0} <- DateTime.from_iso8601(timestamp) do
      {:ok, {at, id}}
    else
      _other -> :error
    end
  end
end
