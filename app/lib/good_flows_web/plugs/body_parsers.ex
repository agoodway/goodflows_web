defmodule GoodFlowsWeb.Plugs.BodyParsers do
  @moduledoc """
  The endpoint's `Plug.Parsers`, except for test report uploads.

  A request whose path is `/api/v1/projects/:project/test-reports` is left
  unparsed (`body_params` and `params` stay `Plug.Conn.Unfetched`), so its
  body is not read before authentication and project resolution.
  `GoodFlowsWeb.Plugs.TestReportBody` reads it later with its own limit.
  Every other request is parsed with the options given here, unchanged.
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Parsers.init(opts)

  @impl Plug
  def call(conn, opts) do
    if test_report_upload?(conn), do: conn, else: Plug.Parsers.call(conn, opts)
  end

  @doc "Whether `conn` (or a path) addresses the test report upload route."
  @spec test_report_upload?(Plug.Conn.t() | [String.t()]) :: boolean()
  def test_report_upload?(%Plug.Conn{path_info: path_info}), do: test_report_upload?(path_info)
  def test_report_upload?(["api", "v1", "projects", _project, "test-reports"]), do: true
  def test_report_upload?(_path_info), do: false
end
