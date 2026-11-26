defmodule GoodFlowsWeb.ScenarioMarkdownTest do
  use ExUnit.Case, async: true

  alias GoodFlowsWeb.ScenarioMarkdown

  defp render(text) do
    text
    |> ScenarioMarkdown.to_html()
    |> Phoenix.HTML.safe_to_string()
    |> LazyHTML.from_fragment()
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "raw HTML, event handlers and script links do not survive" do
    doc =
      render("""
      <script>alert(1)</script>

      Inline <img src=x onerror=alert(1)> and <b onclick="x()">bold</b>.

      [docs](javascript:alert(1)) and [ok](https://example.com)
      """)

    html = doc |> LazyHTML.to_html()

    assert count(doc, "script") == 0
    assert count(doc, "img") == 0
    assert count(doc, "[onerror]") == 0
    assert count(doc, "[onclick]") == 0
    refute html =~ "javascript:"
    refute html =~ "<script"

    # The script link keeps its text with an empty href.
    assert doc |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href") == [
             "",
             "https://example.com"
           ]
  end

  test "fenced code renders as a code block without inline styles" do
    doc = render("```mermaid\ngraph TD; A-->B\n```\n")

    assert count(doc, "pre > code") == 1
    assert count(doc, "[style]") == 0
  end
end
