defmodule GoodFlows.StoredChanges.Files do
  @moduledoc """
  Reads the files of a stored change version for the dashboard:

  - `split/1` splits a file's YAML front matter from its body with the
    rule `GoodFlows.FrontMatter` applies when the server accepts a push.
  - `compare/2` lists the files a version added, removed and changed
    against the version before it, with a line diff for each changed file
    unless either side is over `max_render_bytes/0` UTF-8 bytes, its
    changed region has more than `max_diff_lines/0` lines, or its changed
    region would take the version's diffed lines, counted over changed
    files in path order, past `max_version_diff_lines/0`. A file's changed
    region is the lines of its two versions left after removing the lines
    they share at the start and at the end; only it is diffed.
  """

  @max_render_bytes 262_144
  # List.myers_difference/2 is quadratic in time and memory when every
  # line differs: 500+500 lines take about 150 ms, 2,000+2,000 about 3 s
  # and 1.3 GB (D28). Only the changed region goes through it, so both
  # limits count changed-region lines (D31); the shared start and end are
  # trimmed in linear time.
  @max_diff_lines 1_000
  # The per-file cap alone lets 100 files at the cap take about 25 s, so
  # the lines diffed for one version are bounded too (D30, D31).
  @max_version_diff_lines 1_000
  @context 3

  @typedoc "One line of a line diff, or a run of unchanged lines left out."
  @type row ::
          %{
            op: :eq | :del | :ins,
            old: pos_integer() | nil,
            new: pos_integer() | nil,
            text: String.t()
          }
          | %{op: :skip, count: pos_integer()}

  @typedoc "A file the version added, removed or changed."
  @type entry :: %{
          path: String.t(),
          change: :added | :removed | :changed,
          diff:
            {:lines, [row()]}
            | {:skipped, :too_large | :too_many_lines | :version_budget}
            | nil
        }

  @doc "The most UTF-8 bytes a file may have to render as Markdown or get a line diff."
  @spec max_render_bytes() :: pos_integer()
  def max_render_bytes, do: @max_render_bytes

  @doc "The most lines two versions of a file may have together to get a line diff."
  @spec max_diff_lines() :: pos_integer()
  def max_diff_lines, do: @max_diff_lines

  @doc "The most lines the changed files of one version may have together in line diffs."
  @spec max_version_diff_lines() :: pos_integer()
  def max_version_diff_lines, do: @max_version_diff_lines

  @doc "Whether `text` is too large to render as Markdown."
  @spec too_large?(String.t()) :: boolean()
  def too_large?(text), do: byte_size(text) > @max_render_bytes

  @doc """
  Splits `text` into `{front_matter, body}`. The front matter is the text
  between a first line that is `---` and the next line that is `---`, each
  ignoring one trailing carriage return; without both, it is nil and the
  body is the whole text.
  """
  @spec split(String.t()) :: {String.t() | nil, String.t()}
  def split(text) when is_binary(text) do
    case String.split(text, "\n") do
      [first | rest] ->
        if delimiter?(first), do: front(rest, [], text), else: {nil, text}
    end
  end

  defp front([], _acc, text), do: {nil, text}

  defp front([line | rest], acc, text) do
    if delimiter?(line),
      do: {acc |> Enum.reverse() |> Enum.join("\n"), Enum.join(rest, "\n")},
      else: front(rest, [line | acc], text)
  end

  defp delimiter?(line), do: line == "---" or line == "---\r"

  @doc """
  The files of `files` added, removed or changed against `previous` (nil
  for version 1, whose every file is added), by path.
  """
  @spec compare(%{String.t() => String.t()} | nil, %{String.t() => String.t()}) :: [entry()]
  def compare(previous, files) do
    previous = previous || %{}

    (Map.keys(previous) ++ Map.keys(files))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map_reduce(@max_version_diff_lines, fn path, budget ->
      case {Map.fetch(previous, path), Map.fetch(files, path)} do
        {:error, {:ok, _text}} ->
          {[%{path: path, change: :added, diff: nil}], budget}

        {{:ok, _text}, :error} ->
          {[%{path: path, change: :removed, diff: nil}], budget}

        {{:ok, same}, {:ok, same}} ->
          {[], budget}

        {{:ok, old}, {:ok, new}} ->
          {diff, budget} = line_diff(old, new, budget)
          {[%{path: path, change: :changed, diff: diff}], budget}
      end
    end)
    |> elem(0)
  end

  # Returns the diff and the version's line budget left after it.
  defp line_diff(old, new, budget) do
    if too_large?(old) or too_large?(new) do
      {{:skipped, :too_large}, budget}
    else
      {head, old_mid, new_mid, tail} = trim(lines(old), lines(new))
      count = length(old_mid) + length(new_mid)

      cond do
        count > @max_diff_lines ->
          {{:skipped, :too_many_lines}, budget}

        count > budget ->
          {{:skipped, :version_budget}, budget}

        true ->
          {{:lines, rows(head, old_mid, new_mid, tail)}, budget - count}
      end
    end
  end

  # Splits two line lists into the lines they share at the start, the
  # changed region of each, and the lines they share at the end.
  defp trim(old, new) do
    {head, old_rest, new_rest} = common_prefix(old, new, [])

    {rev_tail, old_mid, new_mid} =
      common_prefix(Enum.reverse(old_rest), Enum.reverse(new_rest), [])

    {Enum.reverse(head), Enum.reverse(old_mid), Enum.reverse(new_mid), rev_tail}
  end

  defp common_prefix([line | old], [line | new], acc), do: common_prefix(old, new, [line | acc])
  defp common_prefix(old, new, acc), do: {acc, old, new}

  defp lines(text) do
    case String.split(text, "\n") do
      [""] -> []
      lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
    end
  end

  # The shared start and end become @context unchanged lines next to the
  # changed region and a skip row for the rest, without a row per line.
  # Texts that differ only in a final newline have the same lines.
  defp rows(head, [], [], []), do: skip(length(head))

  defp rows(head, old_mid, new_mid, tail) do
    {head_skip, head_shown} = Enum.split(head, max(length(head) - @context, 0))
    {tail_shown, tail_skip} = Enum.split(tail, @context)
    first = length(head_skip) + 1

    script =
      [{:eq, head_shown}] ++ List.myers_difference(old_mid, new_mid) ++ [{:eq, tail_shown}]

    {rows, _old, _new} =
      Enum.reduce(script, {[], first, first}, fn {op, lines}, acc ->
        Enum.reduce(lines, acc, &row(op, &1, &2))
      end)

    skip(length(head_skip)) ++
      (rows |> Enum.reverse() |> fold_context()) ++ skip(length(tail_skip))
  end

  defp skip(0), do: []
  defp skip(count), do: [%{op: :skip, count: count}]

  defp row(:eq, text, {acc, old, new}),
    do: {[%{op: :eq, old: old, new: new, text: text} | acc], old + 1, new + 1}

  defp row(:del, text, {acc, old, new}),
    do: {[%{op: :del, old: old, new: nil, text: text} | acc], old + 1, new}

  defp row(:ins, text, {acc, old, new}),
    do: {[%{op: :ins, old: nil, new: new, text: text} | acc], old, new + 1}

  # Keeps @context unchanged lines around each edit and folds the rest.
  defp fold_context(rows) do
    after_edit = distances(rows)
    before_edit = rows |> Enum.reverse() |> distances() |> Enum.reverse()

    [rows, after_edit, before_edit]
    |> Enum.zip_with(fn [row, a, b] -> {row, min(a, b) <= @context} end)
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.flat_map(fn [{_row, keep?} | _] = chunk ->
      if keep?,
        do: Enum.map(chunk, &elem(&1, 0)),
        else: [%{op: :skip, count: length(chunk)}]
    end)
  end

  # For each row, how many rows back the nearest edit is (infinity when none).
  defp distances(rows) do
    {distances, _last} =
      Enum.map_reduce(rows, :infinity, fn row, last ->
        distance = if row.op != :eq, do: 0, else: step(last)
        {distance, distance}
      end)

    distances
  end

  defp step(:infinity), do: :infinity
  defp step(n), do: n + 1
end
