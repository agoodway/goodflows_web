defmodule GoodFlowsWeb.Schemas.TestReportEvent do
  @moduledoc "OpenAPI schema for one test report record, selected by `event`."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.TestReportParts

  OpenApiSpex.schema(%{
    title: "TestReportEvent",
    description:
      "One producer event. Every event carries `event`, `suite_id` (equal to " <>
        "`report.suite_id`), `report_id` (equal to `report.report_id`) and " <>
        "`received_offset_us`, and may carry a flat `meta` object of runner " <>
        "details; the remaining fields depend on `event`.",
    oneOf: TestReportParts.events()
  })
end
