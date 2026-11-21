defmodule GoodFlowsWeb.Api.V1.DefectJSON do
  @moduledoc """
  Renders defects, with the attributed change request as its number.
  Public keys (`redact?: true`) see `ticket` null.
  """

  alias GoodFlows.Calibration.Defect
  alias GoodFlows.ChangeRequests.ChangeRequest

  @doc "Renders one defect."
  def show(%{defect: defect, redact?: redact?}), do: %{data: defect(defect, redact?)}

  @doc "Renders one page of defects."
  def index(%{defects: defects, next_cursor: next_cursor, redact?: redact?}),
    do: %{data: Enum.map(defects, &defect(&1, redact?)), next_cursor: next_cursor}

  defp defect(%Defect{} = defect, redact?) do
    %{
      id: defect.id,
      change_request: number(defect.change_request),
      commit: defect.commit,
      attribution: defect.attribution,
      severity: defect.severity,
      ticket: if(redact?, do: nil, else: defect.ticket),
      recorded_at: DateTime.to_iso8601(defect.recorded_at)
    }
  end

  defp number(%ChangeRequest{number: number}), do: number
  defp number(nil), do: nil
end
