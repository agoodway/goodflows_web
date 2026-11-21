defmodule GoodFlowsWeb.Api.V1.VerifyRunJSON do
  @moduledoc """
  Renders verify runs.

  Public keys (`redact?: true`) see, without the stored run changing and
  without gaining absent fields: each result's `reason` and `failed_step`
  null, each feature's `entry_point` null, `source.changed_files` null,
  `links.threads` null when present, and no artifact URLs. Download URLs
  are given only to private keys, on `final` runs, for unexpired artifacts.
  """

  alias GoodFlows.VerifyRuns
  alias GoodFlows.VerifyRuns.Run

  @doc "Renders an upload acknowledgement with presigned uploads."
  def ack(%{ingested: %{run: run, duplicate: duplicate, uploads: uploads}}) do
    %{
      data: %{
        id: run.id,
        run_id: run.run_id,
        status: run.status,
        duplicate: duplicate,
        expires_at: run.expires_at && DateTime.to_iso8601(run.expires_at),
        uploads:
          Enum.map(uploads, fn upload ->
            %{upload | upload_url_expires_at: DateTime.to_iso8601(upload.upload_url_expires_at)}
          end)
      }
    }
  end

  @doc "Renders one page of run summaries."
  def index(%{runs: runs, next_cursor: next_cursor}) do
    %{data: Enum.map(runs, &summary/1), next_cursor: next_cursor}
  end

  @doc "Renders one run."
  def show(%{run: %Run{} = run, redact?: redact?}) do
    %{
      data: %{
        id: run.id,
        run_id: run.run_id,
        status: run.status,
        inserted_at: DateTime.to_iso8601(run.inserted_at),
        document: if(redact?, do: redact(run.document), else: run.document),
        artifacts: Enum.map(run.artifacts, &artifact(&1, run, redact?))
      }
    }
  end

  defp summary(%Run{} = run) do
    %{
      id: run.id,
      run_id: run.run_id,
      status: run.status,
      started_at: run.document["started_at"],
      finished_at: run.document["finished_at"],
      source: Map.take(run.document["source"], ~w(commit branch dirty)),
      scenario_set: run.document["scenario_set"],
      counts: VerifyRuns.result_counts(run)
    }
  end

  defp artifact(artifact, run, redact?) do
    base = %{id: artifact.artifact_id, expired: artifact.expired}

    if not redact? and run.status == "final" and not artifact.expired do
      download = VerifyRuns.download(artifact)

      Map.merge(base, %{
        download_url: download.url,
        download_url_expires_at: DateTime.to_iso8601(download.expires_at)
      })
    else
      base
    end
  end

  defp redact(document) do
    document
    |> Map.update!("results", fn results ->
      Enum.map(results, &%{&1 | "reason" => nil, "failed_step" => nil})
    end)
    |> Map.update!("features", fn features ->
      Enum.map(features, &%{&1 | "entry_point" => nil})
    end)
    |> Map.update!("source", &%{&1 | "changed_files" => nil})
    |> redact_links()
  end

  defp redact_links(%{"links" => %{"threads" => _} = links} = document),
    do: %{document | "links" => %{links | "threads" => nil}}

  defp redact_links(document), do: document
end
