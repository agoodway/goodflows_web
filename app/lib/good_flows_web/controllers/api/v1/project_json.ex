defmodule GoodFlowsWeb.Api.V1.ProjectJSON do
  @moduledoc "Renders projects for the JSON API. Never includes `account_id`."

  alias GoodFlows.Projects.Project

  @doc "Renders a list of projects."
  def index(%{projects: projects}), do: %{data: Enum.map(projects, &data/1)}

  @doc "Renders one project."
  def show(%{project: project}), do: %{data: data(project)}

  defp data(%Project{} = project) do
    Map.take(project, [:id, :slug, :default_branch, :inserted_at, :updated_at])
  end
end
