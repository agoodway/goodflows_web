defmodule GoodFlowsWeb.Api.V1.RecipeJSON do
  @moduledoc "Renders recipes for the JSON API."

  alias GoodFlows.Spry.Recipe

  @doc "Renders a list of recipes."
  def index(%{recipes: recipes}), do: %{data: Enum.map(recipes, &data/1)}

  @doc "Renders one recipe."
  def show(%{recipe: recipe}), do: %{data: data(recipe)}

  defp data(%Recipe{} = recipe) do
    Map.take(recipe, [:id, :name, :setup, :start, :stop, :teardown, :inserted_at, :updated_at])
  end
end
