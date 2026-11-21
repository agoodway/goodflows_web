defmodule GoodFlows.ReviewPolicies.Glob do
  @moduledoc """
  The review policy glob syntax (design D7).

  A glob is 1 to 1,024 bytes, relative (no leading `/`), without control
  characters and without `[`, `]`, `{`, `}` or `\\`. `**` matches any
  number of whole path segments and must stand alone as a segment, `*`
  matches within one segment, and `?` matches one character other than
  `/`. A glob matches the whole repository-relative path.
  """

  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @max_bytes 1_024
  @forbidden ["[", "]", "{", "}", "\\"]

  @doc "The error message for an invalid glob, or nil when `glob` is valid."
  @spec error(term()) :: String.t() | nil
  def error(glob) when is_binary(glob) do
    cond do
      glob == "" -> "can't be blank"
      byte_size(glob) > @max_bytes -> "is too long"
      Regex.match?(@control, glob) -> "must not contain control characters"
      String.starts_with?(glob, "/") -> "must be relative"
      String.contains?(glob, @forbidden) -> "is invalid"
      partial_double_star?(glob) -> "is invalid"
      true -> nil
    end
  end

  def error(_glob), do: "must be a string"

  defp partial_double_star?(glob) do
    glob |> String.split("/") |> Enum.any?(&(&1 != "**" and String.contains?(&1, "**")))
  end

  @doc "Compiles a valid glob to an anchored regex."
  @spec compile(String.t()) :: Regex.t()
  def compile(glob) when is_binary(glob) do
    body =
      glob
      |> String.split("/")
      |> Enum.map(&element/1)
      |> collapse_globstars([])
      |> build("", false)

    Regex.compile!("\\A" <> body <> "\\z", "u")
  end

  @doc "Whether compiled glob `regex` matches the whole `path`."
  @spec match?(Regex.t(), String.t()) :: boolean()
  def match?(regex, path) when is_binary(path), do: Regex.match?(regex, path)

  defp element("**"), do: :globstar

  defp element(segment) do
    segment
    |> String.codepoints()
    |> Enum.map_join(fn
      "*" -> "[^/]*"
      "?" -> "[^/]"
      char -> Regex.escape(char)
    end)
  end

  defp collapse_globstars([], acc), do: Enum.reverse(acc)

  defp collapse_globstars([:globstar | rest], [:globstar | _] = acc),
    do: collapse_globstars(rest, acc)

  defp collapse_globstars([element | rest], acc), do: collapse_globstars(rest, [element | acc])

  # `**` alone matches every path. Leading, it matches any segments with
  # their trailing `/`; trailing, any segments with their leading `/`; in
  # the middle, `/` then any segments with their trailing `/`.
  defp build([], acc, _separate?), do: acc
  defp build([:globstar], "", _separate?), do: ".*"
  defp build([:globstar | rest], "", _separate?), do: build(rest, "(?:[^/]+/)*", false)
  defp build([:globstar], acc, _separate?), do: acc <> "(?:/[^/]+)*"
  defp build([:globstar | rest], acc, _separate?), do: build(rest, acc <> "/(?:[^/]+/)*", false)

  defp build([segment | rest], acc, separate?),
    do: build(rest, acc <> if(separate?, do: "/", else: "") <> segment, true)
end
