defmodule GoodFlowsWeb.Api.V1.CalibrationController do
  @moduledoc """
  The read-only calibration report at
  `/api/v1/projects/:project/calibration`, on the project read pipeline
  (`sk_` and `pk_` keys; `ck_` keys are `403`). See `GoodFlows.Calibration`.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Calibration
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Schemas.{CalibrationResponse, ErrorResponse, ValidationErrorResponse}
  alias OpenApiSpex.Schema

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Review calibration"])

  operation(:show,
    summary: "Read the calibration report",
    description: """
    Merged change requests and their defects by lane (`auto`, `reviewed`,
    `bypass`), by policy version, by rule that fired and by policy path
    glob, for change requests whose `merged_at` is in `[from, to)`
    (default: the 90 days before now). Every defect attributed to them
    counts, whenever it was recorded. `defects` lists them (at most 500,
    newest first, `defects_truncated` when cut) with their lane, policy
    version, rules and globs; public keys see `ticket` null.
    `unattributed_defect_count` counts unattributed defects recorded in the
    window. Computed on read; reading it never changes the policy.
    """,
    parameters:
      ApiParams.project() ++
        [
          from: [
            in: :query,
            schema: %Schema{type: :string, format: :"date-time"},
            description: "ISO 8601; default 90 days before `to`",
            required: false
          ],
          to: [
            in: :query,
            schema: %Schema{type: :string, format: :"date-time"},
            description: "ISO 8601; default now",
            required: false
          ]
        ],
    responses: [
      ok: {"The report", "application/json", CalibrationResponse},
      unauthorized: {"Missing, expired or revoked API key", "application/json", ErrorResponse},
      forbidden: {"Cache keys", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: {"`Accept` does not allow JSON", "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid `from` or `to`, `from` not before `to`, or invalid project slug",
         "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Reads the calibration report."
  def show(conn, params) do
    with {:ok, report} <- Calibration.report(conn.assigns.project, Map.take(params, ~w(from to))) do
      redact? = not ApiKey.can_write?(conn.assigns.current_api_key)
      json(conn, %{data: report_json(report, redact?)})
    end
  end

  # Public keys see each listed defect's `ticket` as null, as in the
  # defect list.
  defp report_json(report, redact?) do
    %{
      report
      | from: iso8601(report.from),
        to: iso8601(report.to),
        defects:
          Enum.map(report.defects, fn defect ->
            %{
              defect
              | ticket: if(redact?, do: nil, else: defect.ticket),
                recorded_at: DateTime.to_iso8601(defect.recorded_at)
            }
          end)
    }
  end

  defp iso8601(%DateTime{microsecond: {0, _precision}} = datetime),
    do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
