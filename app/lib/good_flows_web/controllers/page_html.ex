defmodule GoodFlowsWeb.PageHTML do
  @moduledoc """
  Templates rendered by `GoodFlowsWeb.PageController`.

  See the `page_html` directory for all templates available.
  """
  use GoodFlowsWeb, :html

  embed_templates "page_html/*"
end
