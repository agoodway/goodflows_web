defmodule GoodFlowsWeb.Plugs.RequireCacheAccess do
  @moduledoc """
  Guards `/api/v1/projects/:project/caches` after `GoodFlowsWeb.Plugs.LoadProject`.

  Halts with `403` for a public (`pk_`) key and for a cache (`ck_`) key of
  another project, then with `503` while no cache bucket is configured.
  The per-scope check needs the request's `scope`, so it runs in the
  controller through `GoodFlows.Accounts.ApiKey.cache_access/4`.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Caches.ObjectStore
  alias GoodFlowsWeb.ErrorJSON

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    %{current_api_key: api_key, project: project} = conn.assigns

    cond do
      api_key.type == :public or
          (ApiKey.cache_key?(api_key) and api_key.project_id != project.id) ->
        conn
        |> put_status(:forbidden)
        |> json(ErrorJSON.render("403.json", %{}))
        |> halt()

      not ObjectStore.configured?() ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{errors: %{detail: "Remote caches are not configured on this server"}})
        |> halt()

      true ->
        conn
    end
  end
end
