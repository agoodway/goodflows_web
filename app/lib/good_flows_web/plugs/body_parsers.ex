defmodule GoodFlowsWeb.Plugs.BodyParsers do
  @moduledoc """
  The endpoint's `Plug.Parsers`, except for raw-body uploads
  (`raw_body_route?/1`).

  Test report uploads and `POST /api/v1/projects/:project/workflow-runs`
  are left unparsed (`body_params` stays `Plug.Conn.Unfetched`), so their
  body is not read before authentication and resource resolution.
  `GoodFlowsWeb.Plugs.TestReportBody` and
  `GoodFlowsWeb.Plugs.WorkflowRunBody` read them later with their own
  limits. `GET` on the workflow-run path is parsed normally, because list
  filters and cursors live in the query string.
  `GoodFlowsWeb.Plugs.RequireParsedBody` and
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

  @doc """
  Whether `conn` (or a path) addresses a route that reads its own raw body.

  The two forms differ for workflow runs. `POST
  /api/v1/projects/:project/workflow-runs` is raw: the body plug reads it
  after authentication. The path-list form returns false for that path.
  `SentryScrubber` and `RequireParsedBody` pass the conn, and a path match
  would skip `Plug.Parsers` on `GET`, leaving `query_params` unfetched and
  dropping list filters and cursors. Test report uploads match in both
  forms, on the path alone, as before.
  """
  @spec raw_body_route?(Plug.Conn.t() | [String.t()]) :: boolean()
  def raw_body_route?(%Plug.Conn{
        method: "POST",
        path_info: ["api", "v1", "projects", _project, "workflow-runs"]
      }),
      do: true

  def raw_body_route?(%Plug.Conn{path_info: path_info}), do: raw_body_route?(path_info)

  def raw_body_route?(path_info) when is_list(path_info),
    do: test_report_upload?(path_info)

  @doc "Whether `conn` (or a path) addresses the test report upload route."
  @spec test_report_upload?(Plug.Conn.t() | [String.t()]) :: boolean()
  def test_report_upload?(%Plug.Conn{path_info: path_info}), do: test_report_upload?(path_info)
  def test_report_upload?(["api", "v1", "projects", _project, "test-reports"]), do: true
  def test_report_upload?(_path_info), do: false
end
