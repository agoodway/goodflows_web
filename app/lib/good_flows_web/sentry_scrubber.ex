defmodule GoodFlowsWeb.SentryScrubber do
  @moduledoc """
  Request body scrubber for `Sentry.PlugContext`. Raw-body uploads (see
  `GoodFlowsWeb.Plugs.BodyParsers.raw_body_route?/1`: test reports, and
  `POST` workflow runs) send no body data to Sentry. Their body is not
  parsed in the endpoint. Every other request, including `GET` workflow
  runs, uses `Sentry.PlugContext.default_body_scrubber/1`.
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
