defmodule GoodFlowsWeb.Schemas.CalibrationLanes do
  @moduledoc "OpenAPI schema for the three calibration lanes."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.CalibrationStats

  OpenApiSpex.schema(%{
    title: "CalibrationLanes",
    description:
      "Each merged change request is in one lane, checked in order: `bypass` " <>
        "(`merge.merged_without_mergeable_verdict` or `merge.merged_without_lease`), " <>
        "`reviewed` (an answered review item at the merged head), else `auto`.",
    type: :object,
    required: [:auto, :reviewed, :bypass],
    properties: %{auto: CalibrationStats, reviewed: CalibrationStats, bypass: CalibrationStats}
  })
end
