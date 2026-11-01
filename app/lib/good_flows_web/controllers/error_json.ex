defmodule GoodFlowsWeb.ErrorJSON do
  @moduledoc """
  Renders JSON error bodies as `{"errors": {"detail": "..."}}`. Invoked by
  the endpoint for JSON requests that fail, and by API plugs/controllers.
  """

  @doc "Renders a JSON error body for a status template such as `\"401.json\"`."
  def render("401.json", _assigns) do
    %{errors: %{detail: "Unauthorized - valid API key required"}}
  end

  def render("403.json", _assigns) do
    %{errors: %{detail: "Forbidden - insufficient permissions"}}
  end

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
