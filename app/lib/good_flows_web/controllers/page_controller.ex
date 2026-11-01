defmodule GoodFlowsWeb.PageController do
  @moduledoc "Public marketing pages."
  use GoodFlowsWeb, :controller

  @doc "Renders the landing page."
  def home(conn, _params) do
    render(conn, :home)
  end
end
