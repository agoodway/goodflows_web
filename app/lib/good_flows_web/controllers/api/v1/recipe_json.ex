defmodule GoodFlowsWeb.Api.V1.RecipeJSON do
  @moduledoc """
  Renders recipes for the JSON API. `project` is the slug of the recipe's
  `project` association, which the `GoodFlows.Spry` recipe functions set from
  the URL's project, so rendering makes no Repo call.
  """

  alias GoodFlows.Projects.Project
  alias GoodFlows.Spry.Recipe

  @doc "Renders a list of recipes."
  def index(%{recipes: recipes}), do: %{data: Enum.map(recipes, &data/1)}

  @doc "Renders one recipe."
  def show(%{recipe: recipe}), do: %{data: data(recipe)}

  defp data(%Recipe{project: %Project{slug: slug}} = recipe) do
    recipe
    |> Map.take([
      :id,
      :project_id,
      :name,
      :setup,
      :start,
      :stop,
      :teardown,
      :inserted_at,
      :updated_at
    ])
    |> Map.put(:project, slug)
  end

  defp data(%Recipe{id: id}) do
    raise ArgumentError,
          "cannot render recipe #{inspect(id)}: its project association must be preloaded " <>
            "(GoodFlows.Spry recipe functions set it from the URL's project)"
  end
end
