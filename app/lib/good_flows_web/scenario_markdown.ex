defmodule GoodFlowsWeb.ScenarioMarkdown do
  @moduledoc """
  Renders an uploaded scenario section as HTML for the change request
  page, in two layers: MDEx (CommonMark and GFM tables, strikethrough and
  autolinks) with raw HTML dropped at the parser and no syntax
  highlighting, then `HtmlSanitizeEx.markdown_html/1`, which keeps only
  its Markdown tags and attributes and only `http`, `https` and `mailto`
  links. The result is the only HTML the page marks safe.
  """

  @options [
    extension: [table: true, strikethrough: true, autolink: true],
    render: [unsafe: false],
    syntax_highlight: nil
  ]

  @doc "The sanitized HTML of Markdown `text`, marked safe for HEEx."
  @spec to_html(String.t()) :: Phoenix.HTML.safe()
  # sobelow_skip ["XSS.Raw"]
  def to_html(text) when is_binary(text) do
    text
    |> MDEx.to_html!(@options)
    |> HtmlSanitizeEx.markdown_html()
    |> Phoenix.HTML.raw()
  end
end
