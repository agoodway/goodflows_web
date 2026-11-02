defmodule GoodFlowsWeb.Plugs.BodyParsers do
  @moduledoc """
  The endpoint's `Plug.Parsers`, except for raw-body routes
  (`raw_body_route?/1`): test report uploads
  (`/api/v1/projects/:project/test-reports`) and pool workspace uploads
  (`/api/v1/pool-sessions/:id/workspace`).

  Those requests are left unparsed (`body_params` and `params` stay
  `Plug.Conn.Unfetched`), so their body is not read before authentication
  and resource resolution. `GoodFlowsWeb.Plugs.TestReportBody` and
  `GoodFlowsWeb.Api.V1.PoolWorkspaceController` read them later with their
  own limits. `GoodFlowsWeb.Plugs.RequireParsedBody` and
  `GoodFlowsWeb.SentryScrubber` use the same predicate. Every other request
  is parsed with the options given here, unchanged.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  @impl Plug
  def call(conn, opts) do
    if raw_body_route?(conn), do: conn, else: Plug.Parsers.call(conn, opts)
  end

  @doc "Whether `conn` (or a path) addresses a route that reads its own raw body."
  @spec raw_body_route?(Plug.Conn.t() | [String.t()]) :: boolean()
  def raw_body_route?(%Plug.Conn{path_info: path_info}), do: raw_body_route?(path_info)

  def raw_body_route?(path_info) when is_list(path_info),
    do: test_report_upload?(path_info) or workspace_upload?(path_info)

  @doc "Whether `conn` (or a path) addresses the pool workspace upload route."
  @spec workspace_upload?(Plug.Conn.t() | [String.t()]) :: boolean()
  def workspace_upload?(%Plug.Conn{path_info: path_info}), do: workspace_upload?(path_info)
  def workspace_upload?(["api", "v1", "pool-sessions", _id, "workspace"]), do: true
  def workspace_upload?(_path_info), do: false

  @doc "Whether `conn` (or a path) addresses the test report upload route."
  @spec test_report_upload?(Plug.Conn.t() | [String.t()]) :: boolean()
  def test_report_upload?(%Plug.Conn{path_info: path_info}), do: test_report_upload?(path_info)
  def test_report_upload?(["api", "v1", "projects", _project, "test-reports"]), do: true
  def test_report_upload?(_path_info), do: false
end
