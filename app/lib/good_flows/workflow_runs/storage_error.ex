defmodule GoodFlows.WorkflowRuns.StorageError do
  @moduledoc """
  Raised by `GoodFlows.WorkflowRuns.ingest/4` in place of an unexpected
  `Postgrex.Error`, whose message and detail can quote the submitted
  document. Only the SQLSTATE and the constraint name are kept.
  """
  defexception [:sqlstate, :constraint]

  @impl Exception
  def message(%__MODULE__{sqlstate: sqlstate}),
    do: "workflow run storage failed (SQLSTATE #{sqlstate || "unknown"})"
end
