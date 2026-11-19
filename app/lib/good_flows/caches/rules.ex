defmodule GoodFlows.Caches.Rules do
  @moduledoc """
  Field rules of the cache wire contract.

  * `key`, `partial` and `sha256` are exactly 64 lowercase hex characters.
  * A scope is an opaque label of 1 to 256 UTF-8 bytes with no control
    characters, compared as an exact byte string. It is not validated as a
    Git branch or ref name. `projects.default_branch` follows the same rule.
  * A cache `name` follows goodflows' name rule: non-blank, at most 64
    bytes, no control characters.

  The scope and name rules are the workflow-run `source.branch` and name
  rules (`GoodFlows.WorkflowRuns.Validator`).
  """

  alias GoodFlows.WorkflowRuns.Validator

  @hex64 ~r/\A[0-9a-f]{64}\z/

  @doc "Human-readable scope rule, for error messages."
  @spec scope_rule() :: String.t()
  def scope_rule, do: "1 to 256 bytes with no control characters"

  @doc "Whether `value` is 64 lowercase hex characters."
  @spec valid_hex64?(term()) :: boolean()
  def valid_hex64?(value) when is_binary(value), do: Regex.match?(@hex64, value)
  def valid_hex64?(_value), do: false

  @doc "Whether `value` follows the scope rule."
  @spec valid_scope?(term()) :: boolean()
  def valid_scope?(value), do: Validator.valid_branch?(value)

  @doc "Whether `value` follows the cache name rule."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(value), do: Validator.valid_name?(value)

  @doc """
  Adds an error to each of `fields` (`:key`, `:partial`, `:sha256`, `:scope`
  or `:name`) whose change breaks its rule. Error messages never contain
  the submitted value.
  """
  @spec validate(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def validate(changeset, fields) do
    Enum.reduce(fields, changeset, &validate_field(&2, &1))
  end

  defp validate_field(changeset, field) do
    {valid?, message} = rule(field)

    Ecto.Changeset.validate_change(changeset, field, fn ^field, value ->
      if valid?.(value), do: [], else: [{field, message}]
    end)
  end

  defp rule(field) when field in [:key, :partial, :sha256],
    do: {&valid_hex64?/1, "must be 64 lowercase hexadecimal characters"}

  defp rule(:scope), do: {&valid_scope?/1, "must be #{scope_rule()}"}

  defp rule(:name),
    do: {&valid_name?/1, "must be 1 to 64 bytes, not blank, with no control characters"}
end
