defmodule GoodFlows.TestReports.Shape do
  @moduledoc """
  A small type checker for normalized JSON values, used by
  `GoodFlows.TestReports.Validator`.

  A spec is one of:

    * `:boolean`, `{:int, min}` (`min` is `nil` for any integer)
    * `{:string, opts}` with `:min`/`:max` UTF-8 byte bounds, an optional
      `:format` regex and `:no_control` (no Unicode control characters)
    * `{:enum, values}`, `{:nullable, spec}`, `{:list, spec}`
    * `{:object, %{key => spec}}`: every key is required and no other key
      is allowed
    * `{:fun, (value, path -> [error]), kind}` for custom checks; `kind`
      is an atom naming the check, so other modules (such as the OpenAPI
      schemas) can describe it

  `check/3` returns a list of `{path, message}` errors in traversal order
  (paths and the accumulator are reversed while checking, then reversed
  once on output). Messages never include the checked value, and an
  unknown key is reported on its enclosing object (`"has an unknown
  field"`) so the submitted key name is never echoed.
  """

  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u

  @typedoc "A shape spec, see the module documentation."
  @type spec :: term()

  @doc "Checks `value` against `spec` at `path` (a reversed path)."
  @spec check(term(), spec(), list()) :: [GoodFlows.TestReports.Document.error()]
  def check(value, spec, path),
    do: value |> do_check(spec, path, []) |> Enum.reverse() |> reverse_paths()

  @doc """
  Like `check/3` but leaves paths reversed and prepends to `errors`, for
  callers that combine many checks.
  """
  @spec check_into(term(), spec(), list(), list()) :: list()
  def check_into(value, spec, path, errors), do: do_check(value, spec, path, errors)

  @doc "Reverses every error path built by `check_into/4`."
  @spec reverse_paths(list()) :: [GoodFlows.TestReports.Document.error()]
  def reverse_paths(errors), do: Enum.map(errors, fn {path, msg} -> {Enum.reverse(path), msg} end)

  defp do_check(nil, {:nullable, _spec}, _path, errors), do: errors
  defp do_check(value, {:nullable, spec}, path, errors), do: do_check(value, spec, path, errors)
  defp do_check(value, :boolean, _path, errors) when is_boolean(value), do: errors
  defp do_check(_value, :boolean, path, errors), do: [{path, "must be a boolean"} | errors]

  defp do_check(value, {:int, min}, path, errors) when is_integer(value) do
    cond do
      min == 0 and value < 0 -> [{path, "must be a nonnegative integer"} | errors]
      min == 1 and value < 1 -> [{path, "must be a positive integer"} | errors]
      true -> errors
    end
  end

  defp do_check(_value, {:int, _min}, path, errors), do: [{path, "must be an integer"} | errors]

  defp do_check(value, {:enum, values}, path, errors) do
    if value in values, do: errors, else: [{path, "is invalid"} | errors]
  end

  defp do_check(value, {:string, opts}, path, errors) when is_binary(value) do
    case string_error(value, opts) do
      nil -> errors
      message -> [{path, message} | errors]
    end
  end

  defp do_check(_value, {:string, _opts}, path, errors), do: [{path, "must be a string"} | errors]

  defp do_check(list, {:list, spec}, path, errors) when is_list(list) do
    {errors, _index} =
      Enum.reduce(list, {errors, 0}, fn item, {errors, index} ->
        {do_check(item, spec, [index | path], errors), index + 1}
      end)

    errors
  end

  defp do_check(_value, {:list, _spec}, path, errors), do: [{path, "must be an array"} | errors]

  defp do_check(map, {:object, fields}, path, errors) when is_map(map) do
    errors =
      Enum.reduce(fields, errors, fn {key, spec}, errors ->
        case Map.fetch(map, key) do
          {:ok, value} -> do_check(value, spec, [key | path], errors)
          :error -> [{[key | path], "is required"} | errors]
        end
      end)

    unknown_errors(map, fields, path, errors)
  end

  defp do_check(_value, {:object, _fields}, path, errors),
    do: [{path, "must be an object"} | errors]

  defp do_check(value, {:fun, fun, _kind}, path, errors), do: fun.(value, path) ++ errors

  @doc """
  Adds one error on `path` itself when `map` has a key that is not in
  `fields`. The submitted key name is never part of the error.
  """
  @spec unknown_errors(map(), map(), list(), list()) :: list()
  def unknown_errors(map, fields, path, errors) do
    if Enum.all?(Map.keys(map), &Map.has_key?(fields, &1)),
      do: errors,
      else: [{path, "has an unknown field"} | errors]
  end

  defp string_error(value, opts) do
    size = byte_size(value)

    cond do
      size < Keyword.get(opts, :min, 0) -> "can't be blank"
      size > Keyword.get(opts, :max, size) -> "is too long"
      opts[:no_control] && Regex.match?(@control, value) -> "must not contain control characters"
      opts[:format] && not Regex.match?(opts[:format], value) -> "has invalid format"
      true -> nil
    end
  end
end
