defmodule GoodFlowsWeb.Api.V1.PreflightController do
  @moduledoc """
  Catch-all `OPTIONS` target for `/api/v1/*`. Phoenix only runs a pipeline
  for a matched route, so without this CORS preflight requests would 404
  before `CORSPlug` (which answers and halts them) ever sees them.
  """
  use GoodFlowsWeb, :controller

  @doc "Answers non-CORS `OPTIONS` requests that `CORSPlug` lets through."
  def options(conn, _params), do: send_resp(conn, :no_content, "")
end
