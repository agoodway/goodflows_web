defmodule GoodFlowsWeb.Api.V1.TestReportController do
  @moduledoc """
  Stores uploaded test reports at `POST /api/v1/projects/:project/test-reports`
  (private keys only). Authentication, write access and the project are
  resolved by the router pipelines before `GoodFlowsWeb.Plugs.TestReportBody`
  admits and reads the body; the action passes only the decoded body to
  `GoodFlows.TestReports.ingest/4`, never `conn.params`, and releases the
  admission slot once ingestion returns.

  A report rejected only for its `format` is logged once at `info`, so
  publishers still running an old CLI are visible on the server: the line
  names the account and project ids, whether the declared format was the
  retired `exunit-timings` or another value (never the value itself), and
  the request `User-Agent` with control characters removed, cut to
  200 bytes.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias GoodFlows.TestReports
  alias GoodFlows.TestReports.{Document, Validator}
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.TestReportBody

  alias GoodFlowsWeb.Schemas.{
    ConflictResponse,
    ErrorResponse,
    TestReportAcknowledgement,
    TestReportRequest,
    ValidationErrorResponse
  }

  plug TestReportBody

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Test reports"])

  operation(:create,
    summary: "Store a test report",
    description: """
    Stores one `test-timings/1` report for the project in the URL, which must
    already exist (it is never created here). The body has no `project` or
    `account_id`; either is rejected as an unknown field.

    The identity is the project, `workflow_run_id`, `job` and
    `report.report_id`. The first upload is `201`. An exact retry (equal JSON
    ignoring object key order) is `200` with the same `id` and
    `duplicate: true`. Any other body under a stored identity is `409`, and
    the stored report never changes, even when it is incomplete.

    `status` is the report's own completion (`complete` only when it ends
    with a clean `suite_finished`, with no interruption, no
    `max_failures_reached` and `truncated` false); failed tests do not make a
    report incomplete, and one partition never completes a whole workflow
    invocation. On `503` the report may or may not be stored: retry the same
    body. There is no read API for stored reports.
    """,
    parameters: ApiParams.project(),
    request_body: {"Test report", "application/json", TestReportRequest, required: true},
    responses: [
      created: {"Stored", "application/json", TestReportAcknowledgement},
      ok: {"Exact retry of a stored report", "application/json", TestReportAcknowledgement},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      request_timeout:
        {"The body was not received before the read deadline", "application/json", ErrorResponse},
      unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
      forbidden: {"Public keys cannot write", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: {"`Accept` does not allow JSON", "application/json", ErrorResponse},
      conflict:
        {"A different report is stored under this identity", "application/json", ConflictResponse},
      request_entity_too_large: {"Body exceeds 32 MiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid report, nesting deeper than 16 levels (on `body`) or invalid project " <>
           "slug; keys are JSON paths such as `report.records[3].duration_us`",
         "application/json", ValidationErrorResponse},
      service_unavailable:
        {"Storage unavailable, or too many concurrent uploads on the node or for the " <>
           "account; retry after `Retry-After`", "application/json", ErrorResponse}
    ]
  )

  @doc """
  Validates and stores the decoded report, then releases the admission slot
  `TestReportBody` took (also when ingestion raises), so the slot covers
  validation and persistence as well as the read.
  """
  def create(conn, _params) do
    %{current_account: account, project: project, current_api_key: api_key} = conn.assigns

    result =
      try do
        TestReports.ingest(account, project, api_key, conn.assigns.test_report_document)
      after
        TestReportBody.finish(conn)
      end

    case result do
      {:ok, ack} ->
        conn
        |> put_status(if ack.duplicate, do: :ok, else: :created)
        |> render(:show, ack: ack)

      {:error, {:invalid_test_report, _errors}} = error ->
        log_format_rejection(conn)
        error

      error ->
        error
    end
  end

  @max_user_agent_bytes 200
  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u

  defp log_format_rejection(conn) do
    %{current_account: account, project: project, test_report_document: document} = conn.assigns

    case Validator.format_rejection(document) do
      nil ->
        :ok

      {path, declared} ->
        format =
          if declared == :retired,
            do: "the retired format exunit-timings",
            else: "an unsupported format"

        Logger.info(
          "Test reports: rejected a report declaring #{format} on " <>
            "#{Document.render_path(path)}, account #{account.id}, project #{project.id}, " <>
            "user agent #{user_agent(conn)}"
        )
    end
  end

  # The header is client text: invalid UTF-8 and control characters are
  # dropped before it is cut to a byte budget on a character boundary.
  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [agent | _] ->
        agent
        |> String.replace_invalid("")
        |> String.replace(@control, "")
        |> truncate_bytes(@max_user_agent_bytes)
        |> inspect()

      [] ->
        "none"
    end
  end

  defp truncate_bytes(text, max) when byte_size(text) <= max, do: text
  defp truncate_bytes(text, max), do: text |> binary_part(0, max) |> String.replace_invalid("")
end
