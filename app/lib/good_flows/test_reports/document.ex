defmodule GoodFlows.TestReports.Document do
  @moduledoc """
  Test-report view of `GoodFlows.JsonDocument`.

  Decoding, normalization, the canonical digest and path rendering are
  shared. This module fixes the nesting cap at 16, the deepest container
  in the test-report contract (body → report → records → record → filters
  → include → entry) plus margin, matching goodflows `MAX_BODY_DEPTH`.
  `check_depth/1` and `max_depth/0` use that cap.

  `normalize/1` errors are `{path, message}` pairs from a fixed list. A
  duplicate or NUL-bearing key is reported on its enclosing object. A
  value error is reported on the value's path, which may pass through
  submitted keys; `GoodFlows.TestReports.Validator` cuts it back to
  contract keys before rendering, so no submitted key name reaches a
  response.

  goodflows (serde_json) reads the number token `-0` as a float, so it is
  never an integer there. `decode/1` decodes it as the float `-0.0`, which
  every integer field rejects like any other fraction (`must be an integer`
  on its path, or `has an invalid value` on a `meta`).
  """

  alias GoodFlows.JsonDocument

  @max_depth 16

  @typedoc "A JSON path as a list of object keys and array indexes."
  @type path :: JsonDocument.path()

  @typedoc "One validation error."
  @type error :: JsonDocument.error()

  @doc "The largest accepted integer magnitude (2^53 - 1)."
  @spec max_integer() :: pos_integer()
  defdelegate max_integer(), to: JsonDocument

  @doc "The deepest accepted object/array nesting (#{@max_depth})."
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Scans `body` without decoding it and returns `{:error, :too_deep}` when
  objects and arrays (outside strings) nest deeper than `max_depth/0`.
  Bracket balance and every other syntax rule are left to `decode/1`.
  """
  @spec check_depth(binary()) :: :ok | {:error, :too_deep}
  def check_depth(body) when is_binary(body), do: JsonDocument.check_depth(body, @max_depth)

  @doc """
  Decodes a JSON body, keeping object key order so duplicates are visible.
  A `-0` number token decodes as the float `-0.0`, as in goodflows.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, :malformed_json}
  defdelegate decode(body), to: JsonDocument

  @doc """
  Converts decoded JSON into plain maps, collecting duplicate-key, NUL and
  integer-range errors. See `GoodFlows.JsonDocument.normalize/1`.
  """
  @spec normalize(term()) :: {:ok, term()} | {:error, [error()]}
  defdelegate normalize(term), to: JsonDocument

  @doc """
  SHA-256 of the canonical JSON of a normalized document. See
  `GoodFlows.JsonDocument.digest/1`.
  """
  @spec digest(term()) :: binary()
  defdelegate digest(term), to: JsonDocument

  @doc """
  Renders a path such as `["report", "records", 3, "duration_us"]` as
  `report.records[3].duration_us`. An empty path renders as `body`.
  """
  @spec render_path(JsonDocument.path()) :: String.t()
  defdelegate render_path(path), to: JsonDocument
end
