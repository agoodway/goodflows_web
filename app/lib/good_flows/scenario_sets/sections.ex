defmodule GoodFlows.ScenarioSets.Sections do
  @moduledoc """
  Splits a stored `qa-scenarios/2` set body into scenario sections for the
  dashboard, with the rules of the goodflows CLI (`markdown::sections`),
  and checks each against the digest the uploader's CLI sent. Uploads
  never call it: they read only the front matter.

  A section lives under the body's `## Scenarios` heading, up to the next
  heading of level 2 or less. A level 3 or 4 heading `<id>. <name>`, with
  `<id>` a scenario of the set, starts one that runs to the next heading
  of the same or a higher level, or the end of the file. ATX headings are
  1 to 6 `#` and a space at the start of a line; lines inside ``` or ~~~
  fences are not headings. Offsets are bytes, as in the CLI.

  A section is shown only when the SHA-256 of its bytes, heading line
  included, equals the stored digest. A heading that is missing, appears
  twice or does not hash to the digest is `:unmatched`, so drift between
  this port and the CLI shows as unmatched text, never the wrong text.
  """

  @typedoc "A scenario's Markdown without its heading line, or `:unmatched`."
  @type section :: {:ok, String.t()} | :unmatched

  @doc """
  The section of each scenario in `sections` (`[%{"id" => id, "sha256" =>
  hex}]`, as stored on a version), keyed by ID.
  """
  @spec split(String.t(), [map()]) :: %{String.t() => section()}
  def split(content, sections) when is_binary(content) and is_list(sections) do
    ids = Enum.map(sections, & &1["id"])
    found = sections_by_id(content, ids)

    Map.new(sections, fn %{"id" => id, "sha256" => sha256} ->
      case Map.get(found, id) do
        [section] -> {id, check(section, sha256)}
        _missing_or_twice -> {id, :unmatched}
      end
    end)
  end

  defp check(section, sha256) do
    if :sha256 |> :crypto.hash(section) |> Base.encode16(case: :lower) == sha256,
      do: {:ok, without_heading(section)},
      else: :unmatched
  end

  defp without_heading(section) do
    rest =
      case :binary.split(section, "\n") do
        [_heading, rest] -> rest
        [_heading] -> ""
      end

    ~r/\A(?:[ \t]*\r?\n)+/
    |> Regex.replace(rest, "")
    |> String.trim_trailing()
  end

  defp sections_by_id(text, ids) do
    headings = headings(text, body_start(text))

    case Enum.drop_while(headings, &(not match?({_offset, 2, "Scenarios"}, &1))) do
      [] ->
        %{}

      [_scenarios | after_first] ->
        after_first
        |> scenario_sections(MapSet.new(ids), text, [])
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    end
  end

  defp scenario_sections([{_offset, level, _title} | _rest], _known, _text, acc) when level <= 2,
    do: Enum.reverse(acc)

  defp scenario_sections([], _known, _text, acc), do: Enum.reverse(acc)

  defp scenario_sections([heading | rest], known, text, acc),
    do: scenario_sections(rest, known, text, section(heading, rest, known, text) ++ acc)

  defp section({start, level, title}, rest, known, text) do
    with true <- level in 3..4,
         [id, _name] <- :binary.split(title, ". "),
         true <- MapSet.member?(known, id) do
      [{id, binary_part(text, start, section_end(rest, level, text) - start)}]
    else
      _other -> []
    end
  end

  defp section_end(rest, level, text) do
    case Enum.find(rest, &(elem(&1, 1) <= level)) do
      nil -> byte_size(text)
      {offset, _level, _title} -> offset
    end
  end

  defp body_start(text) do
    case lines(text, 0) do
      [{_offset, first} | rest] ->
        if without_line_endings(first) == "---", do: front_matter_end(rest), else: 0

      [] ->
        0
    end
  end

  defp front_matter_end(lines) do
    case Enum.find(lines, fn {_offset, line} -> without_line_endings(line) == "---" end) do
      nil -> 0
      {offset, line} -> offset + byte_size(line)
    end
  end

  defp headings(text, body_start) do
    body = binary_part(text, body_start, byte_size(text) - body_start)

    {headings, _fence} =
      body
      |> lines(body_start)
      |> Enum.reduce({[], nil}, fn {offset, line}, {acc, fence} ->
        trimmed = line |> without_line_endings() |> String.trim_leading()
        marker = Enum.find(["```", "~~~"], &String.starts_with?(trimmed, &1))

        cond do
          fence != nil and marker == fence -> {acc, nil}
          fence == nil and marker != nil -> {acc, marker}
          fence != nil -> {acc, fence}
          true -> {heading(offset, line, acc), nil}
        end
      end)

    Enum.reverse(headings)
  end

  defp heading(offset, line, acc) do
    level = count_hashes(line, 0)
    rest = binary_part(line, level, byte_size(line) - level)

    if level in 1..6 and String.starts_with?(rest, " "),
      do: [{offset, level, rest |> without_line_endings() |> String.trim()} | acc],
      else: acc
  end

  defp count_hashes(<<?#, rest::binary>>, n), do: count_hashes(rest, n + 1)
  defp count_hashes(_rest, n), do: n

  defp lines("", _offset), do: []

  defp lines(text, offset) do
    case :binary.match(text, "\n") do
      {at, 1} ->
        line = binary_part(text, 0, at + 1)
        rest = binary_part(text, at + 1, byte_size(text) - at - 1)
        [{offset, line} | lines(rest, offset + at + 1)]

      :nomatch ->
        [{offset, text}]
    end
  end

  defp without_line_endings(line) do
    trimmed = line |> String.trim_trailing("\r") |> String.trim_trailing("\n")
    if trimmed == line, do: line, else: without_line_endings(trimmed)
  end
end
