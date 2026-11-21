defmodule GoodFlows.ChangeRequests.ClaimsDocument.DigitScalar do
  @moduledoc """
  A yamerl node module that keeps yamerl's core-schema integer resolver
  away from long digit runs.

  `yamerl_node_int` tries every plain scalar and builds a bignum one digit
  at a time, which is quadratic in the length of the scalar's leading
  digit run, even when a later character makes the scalar a string.
  `ClaimsDocument` refuses a whole integer longer than `max_digits/0`
  before construction; for any other plain scalar with a longer run, this
  module, placed before the core schema's modules, builds the float or
  string node yamerl would have built, without the integer pass.
  """

  @max_digits 32

  @doc "The longest digit run `yamerl_node_int` is allowed to read."
  @spec max_digits() :: pos_integer()
  def max_digits, do: @max_digits

  @doc """
  Reads a scalar's text the way `yamerl_node_int` does (optional sign,
  then `0x` hex, `0o` octal or decimal digits) and returns whether all of
  it is that integer form, with the number of digits.
  """
  @spec digit_run(charlist()) :: {:integer | :prefix, non_neg_integer()}
  def digit_run([sign | text]) when sign in [?+, ?-], do: run(text)
  def digit_run(text), do: run(text)

  defp run([?0, ?x | text]), do: count(text, &hex?/1, 0)
  defp run([?0, ?o | text]), do: count(text, &(&1 in ?0..?7), 0)
  defp run(text), do: count(text, &(&1 in ?0..?9), 0)

  defp count([], _digit?, n), do: {:integer, n}

  defp count([char | rest], digit?, n) do
    if digit?.(char), do: count(rest, digit?, n + 1), else: {:prefix, n}
  end

  defp hex?(char), do: char in ?0..?9 or char in ?a..?f or char in ?A..?F

  @doc "yamerl node callback: no tags, so nodes are only built by `try_construct_token/3`."
  @spec tags() :: []
  def tags, do: []

  @doc "yamerl node callback, required by yamerl but never reached (there are no tags)."
  @spec construct_token(tuple(), term(), tuple()) :: term()
  def construct_token(constr, node, token),
    do: :yamerl_node_str.construct_token(constr, node, token)

  @doc "yamerl node callback, required by yamerl but never reached (nodes belong to yamerl's modules)."
  @spec node_pres(tuple()) :: term()
  def node_pres(node), do: :yamerl_node_str.node_pres(node)

  @doc """
  yamerl node callback: builds yamerl's own float or string node for a
  plain scalar whose leading digit run is longer than `max_digits/0`, and
  returns `:unrecognized` for every other token.
  """
  @spec try_construct_token(tuple(), term(), tuple()) :: {:finished, tuple()} | :unrecognized
  def try_construct_token(constr, node, {:yamerl_scalar, _, _, tag, _, _, text} = token) do
    with {:yamerl_tag, _, _, {:non_specific, ~c"?"}} <- tag,
         {:prefix, digits} when digits > @max_digits <- digit_run(text),
         :unrecognized <- :yamerl_node_float.try_construct_token(constr, node, token) do
      :yamerl_node_str.try_construct_token(constr, node, token)
    else
      {:finished, _node} = float -> float
      _short_or_not_plain -> :unrecognized
    end
  end

  def try_construct_token(_constr, _node, _token), do: :unrecognized
end
