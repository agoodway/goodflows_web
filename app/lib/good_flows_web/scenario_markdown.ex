defmodule GoodFlowsWeb.ScenarioMarkdown do
  @moduledoc """
  Renders uploaded Markdown as HTML, in two layers: MDEx (CommonMark and
  GFM tables, strikethrough and autolinks) with raw HTML dropped at the
  parser and no syntax highlighting, then `HtmlSanitizeEx.markdown_html/1`,
  which keeps only its Markdown tags and attributes and only `http`,
  `https` and `mailto` links. The result is the only HTML a page marks
  safe.

  The change request page renders scenario sections with `to_html/1`.
  The stored change pages pass `only_scheme_links: true`, which also
  turns every link whose URL does not start with `http:`, `https:` or
  `mailto:` (relative, fragment, protocol-relative) into its text, and
  every image whose URL does not start with `http:` or `https:` into its
  alt text, before the HTML is rendered, since the sanitizer keeps links
  with no scheme. A kept URL's scheme is lower-cased, since the sanitizer
  matches schemes case-sensitively.
  """

  @options [
    extension: [table: true, strikethrough: true, autolink: true],
    render: [unsafe: false],
    syntax_highlight: nil
  ]

  @schemes ~w(http: https: mailto:)
  @image_schemes ~w(http: https:)

  @doc "The sanitized HTML of Markdown `text`, marked safe for HEEx."
  @spec to_html(String.t(), keyword()) :: Phoenix.HTML.safe()
  # sobelow_skip ["XSS.Raw"]
  def to_html(text, opts \\ []) when is_binary(text) do
    source =
      if Keyword.get(opts, :only_scheme_links, false),
        do: text |> MDEx.parse_document!(@options) |> unlink(),
        else: text

    source
    |> MDEx.to_html!(@options)
    |> HtmlSanitizeEx.markdown_html()
    |> Phoenix.HTML.raw()
  end

  defp unlink(%{nodes: nodes} = node) when is_list(nodes),
    do: %{node | nodes: Enum.flat_map(nodes, &unlinked/1)}

  defp unlink(node), do: node

  defp unlinked(%MDEx.Link{url: url, nodes: nodes} = link) do
    case schemed(url, @schemes) do
      {:ok, url} -> [unlink(%{link | url: url})]
      :error -> Enum.flat_map(nodes, &unlinked/1)
    end
  end

  defp unlinked(%MDEx.Image{url: url, nodes: nodes} = image) do
    case schemed(url, @image_schemes) do
      {:ok, url} -> [unlink(%{image | url: url})]
      :error -> Enum.flat_map(nodes, &unlinked/1)
    end
  end

  defp unlinked(node), do: [unlink(node)]

  # The URL with its scheme in lower case when the scheme is one of
  # `schemes`, since the sanitizer matches schemes case-sensitively.
  defp schemed(url, schemes) when is_binary(url) do
    url = String.trim_leading(url)

    with [scheme, rest] <- String.split(url, ":", parts: 2),
         scheme = String.downcase(scheme) <> ":",
         true <- scheme in schemes do
      {:ok, scheme <> rest}
    else
      _other -> :error
    end
  end

  defp schemed(_url, _schemes), do: :error
end
