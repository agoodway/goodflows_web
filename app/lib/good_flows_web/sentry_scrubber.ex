defmodule GoodFlowsWeb.SentryScrubber do
  @moduledoc """
  Request body scrubber for `Sentry.PlugContext`. Raw-body uploads (see
  `GoodFlowsWeb.Plugs.BodyParsers.raw_body_route?/1`: test reports, and
  `POST` workflow runs) send no body data to Sentry. Their body is not
  parsed in the endpoint. Cache routes (`/api/v1/projects/:project/caches`)
  send none either: their exchanges carry presigned URLs, which are bearer
  credentials. Every other request, including `GET` workflow runs, uses
  `Sentry.PlugContext.default_body_scrubber/1`.
  """

  alias GoodFlowsWeb.Plugs.BodyParsers

  @doc "Returns the request data to attach to Sentry events for `conn`."
  @spec scrub(Plug.Conn.t()) :: map()
  def scrub(conn) do
    if BodyParsers.raw_body_route?(conn) or cache_route?(conn),
      do: %{},
      else: Sentry.PlugContext.default_body_scrubber(conn)
  end

  @doc "Whether `conn` targets a cache route."
  @spec cache_route?(Plug.Conn.t()) :: boolean()
  def cache_route?(%Plug.Conn{path_info: ["api", "v1", "projects", _project, "caches" | _rest]}),
    do: true

  def cache_route?(%Plug.Conn{}), do: false
end
