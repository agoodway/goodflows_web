defmodule GoodFlowsWeb.SentryScrubber do
  @moduledoc """
  Request body scrubber for `Sentry.PlugContext`. Raw-body routes (test
  report and pool workspace uploads, see
  `GoodFlowsWeb.Plugs.BodyParsers.raw_body_route?/1`) send no body data to
  Sentry (their body is not even parsed in the endpoint); every other
  request uses `Sentry.PlugContext.default_body_scrubber/1`.
  """

  alias GoodFlowsWeb.Plugs.BodyParsers

  @doc "Returns the request data to attach to Sentry events for `conn`."
  @spec scrub(Plug.Conn.t()) :: map()
  def scrub(conn) do
    if BodyParsers.raw_body_route?(conn),
      do: %{},
      else: Sentry.PlugContext.default_body_scrubber(conn)
  end
end
