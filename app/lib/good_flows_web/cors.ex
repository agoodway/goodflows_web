defmodule GoodFlowsWeb.CORS do
  @moduledoc """
  Allowed CORS origins for the JSON API.

  Passed to `CORSPlug` as a function so origins are read per request.
  `CORSPlug.init/1` runs at compile time in production, so origins set in
  `config/runtime.exs` (from `CORS_ORIGINS`) would otherwise be ignored.
  """

  @doc "Returns the configured list of allowed origins (none by default)."
  @spec origins() :: [String.t()]
  def origins, do: Application.get_env(:good_flows, :cors_origins, [])
end
