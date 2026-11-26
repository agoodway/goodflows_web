defmodule GoodFlowsWeb.VerifyRunArtifactController do
  @moduledoc """
  Evidence downloads from the change request page: redirects a member of
  the account to a presigned download of one artifact of a `final` verify
  run of the project. The URL is presigned per request and never rendered
  into a page or logged. An unknown project, run or artifact, a run that
  is not `final` and an expired artifact are `404`. The router's
  `:load_account` plug sends non-members to `/dashboard` before this runs.
  """
  use GoodFlowsWeb, :controller

  alias GoodFlows.Projects
  alias GoodFlows.VerifyRuns
  alias GoodFlows.VerifyRuns.{Artifact, Run}

  @doc "Redirects to the artifact's presigned download URL, or responds 404."
  def show(conn, %{"slug" => slug, "run_id" => run_id, "artifact_id" => artifact_id}) do
    with {:ok, project} <- Projects.get_project(conn.assigns.current_account, slug),
         {:ok, %Run{status: "final"} = run} <- VerifyRuns.get(project, run_id),
         %Artifact{expired: false} = artifact <-
           Enum.find(run.artifacts, &(&1.artifact_id == artifact_id)) do
      redirect(conn, external: VerifyRuns.download(artifact).url)
    else
      _not_downloadable ->
        conn
        |> put_status(:not_found)
        |> put_view(html: GoodFlowsWeb.ErrorHTML)
        |> render(:"404")
    end
  end
end
