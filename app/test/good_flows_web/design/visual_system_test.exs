defmodule GoodFlowsWeb.Design.VisualSystemTest do
  @moduledoc """
  Guards the rules in `DESIGN.md` that a scan can check: colours come from
  theme tokens, and pages use the shared components instead of
  hand-written daisyUI markup.
  """
  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)
  @templates Path.wildcard(Path.join(@app_root, "lib/good_flows_web/**/*.{ex,heex}"))
  @css Path.join(@app_root, "assets/css/app.css")

  @palette ~w(slate gray zinc neutral stone red orange amber yellow lime green emerald teal
              cyan sky blue indigo violet purple fuchsia pink rose black white)
  @utilities ~w(text bg border ring outline fill stroke from via to divide decoration accent
                caret shadow placeholder)

  @hex ~r/#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})(?![\w-])/
  @palette_class ~r/(?<![\w-])(?:#{Enum.join(@utilities, "|")})-(?:#{Enum.join(@palette, "|")})(?:-\d{2,3})?(?![\w-])/

  # Each of these has a shared component; writing the daisyUI class by hand
  # bypasses it.
  @hand_written [
    {~r/(?<![\w-])btn(?:-[a-z]+)*(?![\w-])/, "use <.button>"},
    {~r/(?<![\w-])badge(?:-[a-z]+)*(?![\w-])/, "use <.status_badge> or <.tag>"},
    {~r/modal modal-open|(?<![\w-])modal-box(?![\w-])/,
     "use <.editor_dialog> or <.confirm_dialog>"},
    {~r/(?<![\w-])alert(?:-[a-z]+)*(?![\w-])/, "use <.notice> or <.flash>"},
    {~r/data-confirm/, "use <.confirm_dialog>"},
    {~r/(?<![\w-])outline-none(?![\w-])/, "keep a visible focus outline"}
  ]

  test "there are templates to scan" do
    assert length(@templates) > 10
  end

  test "templates use no hex colours" do
    assert offences(@templates, @hex) == []
  end

  test "templates use no Tailwind palette colours" do
    assert offences(@templates, @palette_class) == []
  end

  test "the stylesheet uses no hex colours" do
    assert offences([@css], @hex) == []
  end

  for {pattern, advice} <- @hand_written do
    test "templates do not hand-write #{inspect(Regex.source(pattern))}: #{advice}" do
      assert offences(@templates, unquote(Macro.escape(pattern))) == []
    end
  end

  # Returns "path:line: text" for each line of markup or CSS that matches.
  defp offences(paths, pattern) do
    for path <- paths,
        {line, number} <- path |> File.read!() |> scannable() |> Enum.with_index(1),
        Regex.match?(pattern, line) do
      "#{Path.relative_to(path, @app_root)}:#{number}: #{String.trim(line)}"
    end
  end

  # Blanks out prose so only markup and code are scanned: `@doc` and
  # `@moduledoc` heredocs, comment lines, `doc:` strings and visible role names.
  defp scannable(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_doc? ->
      cond do
        in_doc? -> {"", String.trim(line) != ~s(""")}
        line =~ ~r/^\s*@(?:doc|moduledoc) """/ -> {"", true}
        line =~ ~r/^\s*(?:#|\/\*|\*|<%!--)/ -> {"", false}
        true -> {String.replace(line, ~r/doc: ".*?"|role="alert"/, ""), false}
      end
    end)
    |> elem(0)
  end
end
