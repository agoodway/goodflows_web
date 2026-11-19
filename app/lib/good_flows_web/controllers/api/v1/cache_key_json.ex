defmodule GoodFlowsWeb.Api.V1.CacheKeyJSON do
  @moduledoc "Renders cache keys. The token appears only in the mint response."

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Caches.Keys

  @doc "Renders a minted key with its token."
  def show(%{api_key: api_key, token: token}) do
    %{
      data: %{
        id: api_key.id,
        token: token,
        access: Keys.access(api_key.type),
        scope: api_key.scope,
        expires_at: api_key.expires_at
      }
    }
  end

  @doc "Renders a page of keys without tokens."
  def index(%{page: page}) do
    %{data: Enum.map(page.keys, &data/1), next_cursor: page.next_cursor}
  end

  defp data(%ApiKey{} = api_key) do
    api_key
    |> Map.take([:id, :name, :scope, :token_prefix, :expires_at, :last_used_at, :inserted_at])
    |> Map.put(:access, Keys.access(api_key.type))
  end
end
