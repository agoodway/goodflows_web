defmodule GoodFlowsWeb.Api.V1.WorkflowRunJSON do
  @moduledoc """
  Renders workflow-run acknowledgements, list summaries and show responses.

  Summaries rebuild `source` from the copied columns: null when no commit
  was stored, otherwise `commit` plus `dirty` and `branch` only when each
  was stored. `host` and `ci` are the stored objects (`ci` null when the
  document had none), so omitted keys stay omitted. `failed_jobs` names the
  `failed` and `timed_out` results; public keys see it too, because job
  names are not redacted from their view of a document.

  Public keys (`redact?: true`) see each `results` entry's `command` and
  `error` as null, and in `graph` each job's and step's `command` and each
  condition's `text` as null. They also see `links.threads` as null when
  the document has it; a document without `links.threads` gains no such
  key, and `links.tickets` is as stored. The stored row is never written
  here.

  The `links.threads` redaction stays in a code rollback of `links`
  support (design D5 of `accept-run-links`): runs stored while `links` was
  accepted keep it in `payload`, so it must stay hidden from public keys.
  It depends only on the stored document, not on validation or filters.
  """

  alias GoodFlows.TestReports.Report
  alias GoodFlows.WorkflowRuns.Run

  @doc """
  Renders an upload acknowledgement, or one stored run.

  The acknowledgement does not include the document. A show render redacts
  command text, errors, graph condition text and thread URLs when
  `redact?` is true.
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
      ci: run.ci,
      host: run.host,
      failed_jobs: run.failed_jobs,
      inserted_at: DateTime.to_iso8601(run.inserted_at)
    }
  end

  defp source(%Run{source_commit: nil}), do: nil

  defp source(%Run{} = run) do
    %{commit: run.source_commit}
    |> put_present(:dirty, run.source_dirty)
    |> put_present(:branch, run.source_branch)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp document(payload, false), do: payload

  defp document(payload, true) do
    payload
    |> update_list("results", &redact_result/1)
    |> redact_graph()
    |> redact_threads()
  end

  defp redact_threads(%{"links" => %{"threads" => _threads} = links} = payload),
    do: %{payload | "links" => %{links | "threads" => nil}}

  defp redact_threads(payload), do: payload

  defp redact_result(result) do
    result |> Map.put("command", nil) |> Map.put("error", nil)
  end

  defp redact_graph(%{"graph" => graph} = payload),
    do: %{payload | "graph" => update_list(graph, "jobs", &redact_job/1)}

  defp redact_graph(payload), do: payload

  # A call job's `call` names a workflow and a hash, not command text.
  defp redact_job(job) do
    job
    |> Map.put("command", nil)
    |> redact_condition()
    |> update_list("steps", &(&1 |> Map.put("command", nil) |> redact_condition()))
  end

  defp redact_condition(%{"condition" => %{} = condition} = item),
    do: %{item | "condition" => %{condition | "text" => nil}}

  defp redact_condition(item), do: item

  defp update_list(map, key, fun) do
    case map do
      %{^key => list} when is_list(list) -> %{map | key => Enum.map(list, fun)}
      _other -> map
    end
  end

  defp report_summary(%Report{} = report), do: Map.take(report, Report.summary_fields())
end
