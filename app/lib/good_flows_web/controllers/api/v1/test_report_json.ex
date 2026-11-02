defmodule GoodFlowsWeb.Api.V1.TestReportJSON do
  @moduledoc """
  Renders test report storage acknowledgements. Never includes the stored
  document, the project or the account.
  """

  @doc "Renders an acknowledgement."
  def show(%{ack: ack}), do: %{data: Map.take(ack, [:id, :report_id, :status, :duplicate])}
end
