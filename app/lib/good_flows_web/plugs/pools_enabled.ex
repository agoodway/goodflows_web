defmodule GoodFlowsWeb.Plugs.PoolsEnabled do
  @moduledoc """
  Halts pool (except `DELETE /pools/:pool`, which stays available for
  rollback cleanup), session, workspace, and report requests with `503`
  while Sprite pools are unavailable on this node: switched off
  (`POOLS_ENABLED=false`) or without a valid helper manifest
  (`GoodFlows.Pools.Config.enabled?/0`). Runs after authentication, so
  `401` and `403` still come first.
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias GoodFlows.Pools.Config

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Config.enabled?() do
      conn
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{errors: %{detail: "Sprite pools are disabled on this server"}})
      |> halt()
    end
  end
end
