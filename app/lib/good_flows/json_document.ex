defmodule GoodFlows.JsonDocument do
  @moduledoc """
  Decodes a JSON document and turns it into plain maps and lists.

  The body is decoded with `objects: :ordered_objects` so a duplicate object
  key can be detected; `normalize/1` rejects duplicate keys, strings or keys
  containing U+0000 (Postgres JSONB cannot store them) and integers outside
  `±(2^53 - 1)`. Errors are `{path, message}` pairs, in document order,
  where `path` is a list of keys and indexes and `message` comes from a
  fixed list: no submitted value is ever echoed, and a duplicate or
  NUL-bearing key is reported on its enclosing object. A value error is
  reported on the value's path, which may pass through submitted keys.
  Callers that render errors cut those paths back to contract keys.

  `check_depth/2` bounds container nesting before decoding, so a
  pathologically nested body is rejected by a cheap byte scan instead of
  being decoded. The limit is an argument because each document type has
  its own cap.

  goodflows (serde_json) reads the number token `-0` as a float, so it is
  never an integer there. `Jason` would decode it as the integer `0`;
  `decode/1` instead decodes it as the float `-0.0`, which integer fields
  reject like any other fraction.
  """

  alias Jason.OrderedObject

  @max_integer 9_007_199_254_740_991

  @typedoc "A JSON path as a list of object keys and array indexes."
  @type path :: [String.t() | non_neg_integer()]

  @typedoc "One validation error."
  @type error :: {path(), String.t()}

  @doc "The largest accepted integer magnitude (2^53 - 1)."
  @spec max_integer() :: pos_integer()
  def max_integer, do: @max_integer

  @doc """
  Scans `body` without decoding it and returns `{:error, :too_deep}` when
  objects and arrays (outside strings) nest deeper than `limit`.
  Bracket balance and every other syntax rule are left to `decode/1`.
  """
  @spec check_depth(binary(), non_neg_integer()) :: :ok | {:error, :too_deep}
  def check_depth(body, limit) when is_binary(body) and is_integer(limit) and limit >= 0,
    do: scan(body, 0, limit)

  defp scan(<<?", rest::binary>>, depth, limit), do: scan_string(rest, depth, limit)

  defp scan(<<char, rest::binary>>, depth, limit) when char in [?{, ?[] do
    if depth >= limit, do: {:error, :too_deep}, else: scan(rest, depth + 1, limit)
  end

  defp scan(<<char, rest::binary>>, depth, limit) when char in [?}, ?]],
    do: scan(rest, depth - 1, limit)

  defp scan(<<_char, rest::binary>>, depth, limit), do: scan(rest, depth, limit)
  defp scan(<<>>, _depth, _limit), do: :ok

  defp scan_string(<<?\\, _escaped, rest::binary>>, depth, limit),
    do: scan_string(rest, depth, limit)

  defp scan_string(<<?", rest::binary>>, depth, limit), do: scan(rest, depth, limit)
  defp scan_string(<<_char, rest::binary>>, depth, limit), do: scan_string(rest, depth, limit)
  defp scan_string(<<>>, _depth, _limit), do: :ok

  @doc """
  Decodes a JSON body, keeping object key order so duplicates are visible.
  A `-0` number token decodes as the float `-0.0`, as in goodflows.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, :malformed_json}
  def decode(body) when is_binary(body) do
    case Jason.decode(negative_zero_as_float(body), objects: :ordered_objects) do
      {:ok, term} -> {:ok, term}
      {:error, %Jason.DecodeError{}} -> {:error, :malformed_json}
    end
  end

  # Appends `.0` to every `-0` number token outside strings (one not
  # already followed by a fraction, exponent or digit), so it decodes as a
  # float. In valid JSON a number token follows `[`, `:`, `,`, whitespace
  # or the start of the body, never a letter or digit, so the full scan
  # runs only when some `-0` is not preceded by an ASCII letter or digit.
  # Dates (`2026-01-05`) and UUIDs (`…-0abc…`) do not trigger it; an
  # exponent (`1e-0`) is skipped by the same rule.
  defp negative_zero_as_float(body) do
    if Regex.match?(~r/(?:\A|[^0-9A-Za-z])-0/, body),
      do: body |> splice_fractions(negative_zeros(body, 0, []), 0, []) |> IO.iodata_to_binary(),
      else: body
  end

  defp splice_fractions(body, [], from, acc),
    do: [acc, binary_part(body, from, byte_size(body) - from)]

  defp splice_fractions(body, [at | rest], from, acc),
    do: splice_fractions(body, rest, at, [acc, binary_part(body, from, at - from), ".0"])

  # Offsets just after each bare `-0` token, ascending.
  defp negative_zeros(<<?", rest::binary>>, pos, acc),
    do: negative_zeros_string(rest, pos + 1, acc)

  # An exponent sign: `1e-0` is already a float.
  defp negative_zeros(<<e, sign, rest::binary>>, pos, acc)
       when e in [?e, ?E] and sign in [?-, ?+],
       do: negative_zeros(rest, pos + 2, acc)

  defp negative_zeros(<<?-, ?0, rest::binary>>, pos, acc) do
    acc = if continues_number?(rest), do: acc, else: [pos + 2 | acc]
    negative_zeros(rest, pos + 2, acc)
  end

  defp negative_zeros(<<_char, rest::binary>>, pos, acc), do: negative_zeros(rest, pos + 1, acc)
  defp negative_zeros(<<>>, _pos, acc), do: Enum.reverse(acc)

  defp continues_number?(<<next, _rest::binary>>), do: next in ~c".eE0123456789"
  defp continues_number?(<<>>), do: false

  defp negative_zeros_string(<<?\\, _escaped, rest::binary>>, pos, acc),
    do: negative_zeros_string(rest, pos + 2, acc)

  defp negative_zeros_string(<<?", rest::binary>>, pos, acc),
    do: negative_zeros(rest, pos + 1, acc)

  defp negative_zeros_string(<<_char, rest::binary>>, pos, acc),
    do: negative_zeros_string(rest, pos + 1, acc)

  defp negative_zeros_string(<<>>, _pos, acc), do: Enum.reverse(acc)

  @doc """
  Converts decoded JSON into plain maps, collecting duplicate-key, NUL and
  integer-range errors. Plain maps are accepted too (no duplicate check is
  possible for them).

  A value error's path is the value's own path, which can include
  submitted keys (for example an unknown key). A duplicate key or a key
  containing U+0000 is reported on the enclosing object.
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
