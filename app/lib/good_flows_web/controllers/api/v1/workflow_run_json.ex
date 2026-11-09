defmodule GoodFlowsWeb.Api.V1.WorkflowRunJSON do
  @moduledoc """
  Renders workflow-run acknowledgements, list summaries and show responses.

  Summaries rebuild `source` from the copied columns: null when no commit
  was stored, otherwise `commit` plus `dirty` only when `dirty` was stored.
  `host` is the stored object, so omitted memory fields stay omitted.

  Public keys (`redact?: true`) see each `results` entry's `command` and
  `error` as null. The stored row is never written here.
  """

  alias GoodFlows.TestReports.Report
  alias GoodFlows.WorkflowRuns.Run

  @doc """
  Renders an upload acknowledgement, or one stored run.

  The acknowledgement does not include the document. A show render redacts
  each result's `command` and `error` when `redact?` is true.
  """
  def show(%{ack: ack}), do: %{data: Map.take(ack, [:id, :run_id, :duplicate])}

  def show(%{run: %Run{} = run, test_reports: reports, redact?: redact?}) do
    %{
      data: %{
        id: run.id,
        run_id: run.run_id,
        inserted_at: DateTime.to_iso8601(run.inserted_at),
        document: document(run.payload, redact?),
        test_reports: Enum.map(reports, &report_summary/1)
      }
    }
  end

  @doc "Renders one page of summaries. `next_cursor` is nil on the last page."
  def index(%{runs: runs, next_cursor: next_cursor}) do
    %{data: Enum.map(runs, &summary/1), next_cursor: next_cursor}
  end

  defp summary(%Run{} = run) do
    %{
      id: run.id,
      run_id: run.run_id,
      workflow: run.workflow,
      environment: run.environment,
      outcome: run.outcome,
      started_at: DateTime.to_iso8601(run.started_at),
      duration_ms: run.duration_ms,
      parallelism: run.parallelism,
      max_in_flight: run.max_in_flight,
      graph_sha256: run.graph_sha256,
      source: source(run),
      host: run.host,
      inserted_at: DateTime.to_iso8601(run.inserted_at)
    }
  end

  defp source(%Run{source_commit: nil}), do: nil
  defp source(%Run{source_commit: commit, source_dirty: nil}), do: %{commit: commit}

  defp source(%Run{source_commit: commit, source_dirty: dirty}),
    do: %{commit: commit, dirty: dirty}

  defp document(payload, false), do: payload

  defp document(%{"results" => results} = payload, true) when is_list(results) do
    %{payload | "results" => Enum.map(results, &redact_result/1)}
  end

  defp document(payload, true), do: payload

  defp redact_result(result) when is_map(result) do
    result |> Map.put("command", nil) |> Map.put("error", nil)
  end

  defp redact_result(result), do: result

  defp report_summary(%Report{} = report), do: Map.take(report, Report.summary_fields())
end
