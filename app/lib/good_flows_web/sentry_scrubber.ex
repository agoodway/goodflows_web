defmodule GoodFlowsWeb.SentryScrubber do
  @moduledoc """
  Request body scrubber for `Sentry.PlugContext`. Test report uploads send
  no body data to Sentry (their body is not even parsed in the endpoint);
  every other request uses `Sentry.PlugContext.default_body_scrubber/1`.
  """

  alias GoodFlowsWeb.Plugs.BodyParsers

  @doc "Returns the request data to attach to Sentry events for `conn`."
  @spec scrub(Plug.Conn.t()) :: map()
  def scrub(conn) do
    if BodyParsers.test_report_upload?(conn),
      do: %{},
      else: Sentry.PlugContext.default_body_scrubber(conn)
  end
end
