defmodule GoodFlows.TestReports.Document do
  @moduledoc """
  Decodes a test report request body and turns the decoded JSON into plain
  maps and lists.

  The body is decoded with `objects: :ordered_objects` so a duplicate object
  key can be detected; `normalize/1` rejects duplicate keys, strings or keys
  containing U+0000 (Postgres JSONB cannot store them) and integers outside
  `±(2^53 - 1)`. Errors are `{path, message}` pairs, in document order,
  where `path` is a list of contract keys and indexes and `message` comes
  from a fixed list: no submitted value or submitted key name is ever
  echoed (a duplicate or NUL-bearing key is reported on its enclosing
  object).

  `check_depth/1` bounds container nesting before decoding, so a
  pathologically nested body is rejected by a cheap byte scan instead of
  being decoded.
  """

  alias Jason.OrderedObject

  @max_integer 9_007_199_254_740_991

  # The deepest container in the D1 contract is 8 levels (body → report →
  # records → record → files → file → bucket → counts); 16 leaves margin.
  @max_depth 16

  @typedoc "A JSON path as a list of object keys and array indexes."
  @type path :: [String.t() | non_neg_integer()]

  @typedoc "One validation error."
  @type error :: {path(), String.t()}

  @doc "The largest accepted integer magnitude (2^53 - 1)."
  @spec max_integer() :: pos_integer()
  def max_integer, do: @max_integer

  @doc "The deepest accepted object/array nesting (#{@max_depth})."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Scans `body` without decoding it and returns `{:error, :too_deep}` when
  objects and arrays (outside strings) nest deeper than `max_depth/0`.
  Bracket balance and every other syntax rule are left to `decode/1`.
  """
  @spec check_depth(binary()) :: :ok | {:error, :too_deep}
  def check_depth(body) when is_binary(body), do: scan(body, 0)

  defp scan(<<?", rest::binary>>, depth), do: scan_string(rest, depth)

  defp scan(<<char, rest::binary>>, depth) when char in [?{, ?[] do
    if depth >= @max_depth, do: {:error, :too_deep}, else: scan(rest, depth + 1)
  end

  defp scan(<<char, rest::binary>>, depth) when char in [?}, ?]], do: scan(rest, depth - 1)
  defp scan(<<_char, rest::binary>>, depth), do: scan(rest, depth)
  defp scan(<<>>, _depth), do: :ok

  defp scan_string(<<?\\, _escaped, rest::binary>>, depth), do: scan_string(rest, depth)
  defp scan_string(<<?", rest::binary>>, depth), do: scan(rest, depth)
  defp scan_string(<<_char, rest::binary>>, depth), do: scan_string(rest, depth)
  defp scan_string(<<>>, _depth), do: :ok

  @doc "Decodes a JSON body, keeping object key order so duplicates are visible."
  @spec decode(binary()) :: {:ok, term()} | {:error, :malformed_json}
  def decode(body) when is_binary(body) do
    case Jason.decode(body, objects: :ordered_objects) do
      {:ok, term} -> {:ok, term}
      {:error, %Jason.DecodeError{}} -> {:error, :malformed_json}
    end
  end

  @doc """
  Converts decoded JSON into plain maps, collecting duplicate-key, NUL and
  integer-range errors. Plain maps are accepted too (no duplicate check is
  possible for them).
  """
  @spec normalize(term()) :: {:ok, term()} | {:error, [error()]}
  def normalize(term) do
    case normalize(term, [], []) do
      {value, []} -> {:ok, value}
      {_value, errors} -> {:error, Enum.reverse(errors)}
    end
  end

  defp normalize(%OrderedObject{values: pairs}, path, errors) do
    normalize_pairs(pairs, path, errors)
  end

  defp normalize(map, path, errors) when is_map(map) and not is_struct(map) do
    normalize_pairs(Map.to_list(map), path, errors)
  end

  defp normalize(list, path, errors) when is_list(list) do
    {values, errors, _index} =
      Enum.reduce(list, {[], errors, 0}, fn item, {acc, errors, index} ->
        {value, errors} = normalize(item, [index | path], errors)
        {[value | acc], errors, index + 1}
      end)

    {Enum.reverse(values), errors}
  end

  defp normalize(string, path, errors) when is_binary(string) do
    if nul?(string),
      do: {string, [{Enum.reverse(path), "must not contain NUL characters"} | errors]},
      else: {string, errors}
  end

  defp normalize(int, path, errors) when is_integer(int) do
    if abs(int) > @max_integer,
      do: {int, [{Enum.reverse(path), "is out of range"} | errors]},
      else: {int, errors}
  end

  defp normalize(other, _path, errors), do: {other, errors}

  defp normalize_pairs(pairs, path, errors) do
    {map, errors} =
      Enum.reduce(pairs, {%{}, errors}, fn {key, item}, {map, errors} ->
        cond do
          nul?(key) ->
            {map, [{Enum.reverse(path), "must not contain NUL characters"} | errors]}

          Map.has_key?(map, key) ->
            {map, [{Enum.reverse(path), "has a duplicate key"} | errors]}

          true ->
            {value, errors} = normalize(item, [key | path], errors)
            {Map.put(map, key, value), errors}
        end
      end)

    {map, errors}
  end

  defp nul?(string) when is_binary(string), do: :binary.match(string, <<0>>) != :nomatch
  defp nul?(_other), do: false

  @doc """
  SHA-256 of the canonical JSON of a normalized document: object keys
  sorted by their UTF-8 bytes, no whitespace, strings and integers as
  `Jason` encodes them. Two documents have the same digest exactly when
  they are the same JSON value (key order ignored, arrays in order).
  """
  @spec digest(term()) :: binary()
  def digest(term), do: :crypto.hash(:sha256, canonical(term))

  defp canonical(map) when is_map(map) do
    pairs =
      map
      |> Map.to_list()
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> [Jason.encode_to_iodata!(key), ?:, canonical(value)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp canonical(list) when is_list(list),
    do: [?[, list |> Enum.map(&canonical/1) |> Enum.intersperse(?,), ?]]

  defp canonical(scalar), do: Jason.encode_to_iodata!(scalar)

  @doc """
  Renders a path such as `["report", "records", 3, "duration_us"]` as
  `report.records[3].duration_us`. An empty path renders as `body`.

  Paths only hold contract keys (errors about submitted keys are reported
  on the enclosing object). As a defence in depth the path still stops
  before any key that is not 1 to 64 ASCII letters, digits or underscores.
  """
  @spec render_path(path()) :: String.t()
  def render_path(path) do
    path
    |> Enum.take_while(&safe_segment?/1)
    |> Enum.with_index()
    |> Enum.map(fn
      {index, _position} when is_integer(index) -> ["[", Integer.to_string(index), "]"]
      {key, 0} -> key
      {key, _position} -> [".", key]
    end)
    |> IO.iodata_to_binary()
    |> case do
      "" -> "body"
      rendered -> rendered
    end
  end

  defp safe_segment?(index) when is_integer(index), do: true
  defp safe_segment?(key), do: Regex.match?(~r/\A[A-Za-z0-9_]{1,64}\z/, key)
end
