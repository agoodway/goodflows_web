defmodule GoodFlows.Spry.Template do
  @moduledoc """
  `{{…}}` placeholder handling for recipe sprite names and step lines, ported
  from spry's `template.rs`.

  Placeholders are case-sensitive and allow no interior whitespace. The sprite
  name may use `branch`, `branch_slug`, `commit`, and `remote`; step lines may
  also use `sprite`. Anything else (including `{{org}}` and `{{ branch }}`) is
  unknown. Expansion is a single, non-recursive, unquoted substitution.
  """

  @name_placeholders ~w(branch branch_slug commit remote)
  @step_placeholders ~w(branch branch_slug commit remote sprite)
  @token ~r/\{\{(.*?)\}\}/s
  @sprite_name ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/

  @sprite_name_rule "lowercase letters, digits, and hyphens, starting with a letter or " <>
                      "digit, at most 63 characters"

  @type context :: :name | :step

  @doc "Placeholder names allowed in the given context."
  @spec allowed(context()) :: [String.t()]
  def allowed(:name), do: @name_placeholders
  def allowed(:step), do: @step_placeholders

  @doc """
  Lists the placeholders in `string`, in order of first appearance.

  Returns `{:ok, names}` when every placeholder is allowed in `context`, or
  `{:error, {:unknown, names}}` listing the unknown ones.
  """
  @spec scan(String.t(), context()) :: {:ok, [String.t()]} | {:error, {:unknown, [String.t()]}}
  def scan(string, context) when is_binary(string) and context in [:name, :step] do
    names = placeholders(string)
    allowed = allowed(context)

    case Enum.reject(names, &(&1 in allowed)) do
      [] -> {:ok, names}
      unknown -> {:error, {:unknown, unknown}}
    end
  end

  @doc """
  Substitutes each placeholder with its value from `values` (string keys).

  A placeholder whose value is missing, `nil`, or empty returns
  `{:error, {:missing, name}}` for the first such placeholder. Substituted
  values are inserted verbatim and are never re-expanded.
  """
  @spec expand(String.t(), %{optional(String.t()) => String.t() | nil}) ::
          {:ok, String.t()} | {:error, {:missing, String.t()}}
  def expand(string, values) when is_binary(string) and is_map(values) do
    case Enum.find(placeholders(string), &blank?(Map.get(values, &1))) do
      nil -> {:ok, Regex.replace(@token, string, fn _whole, name -> Map.fetch!(values, name) end)}
      name -> {:error, {:missing, name}}
    end
  end

  @doc """
  Derives a branch slug: each run of characters outside `[A-Za-z0-9._-]`
  becomes one `-`, then leading and trailing `-` are stripped. Case is kept.
  """
  @spec slug(String.t()) :: String.t()
  def slug(branch) when is_binary(branch) do
    ~r/[^A-Za-z0-9._-]+/
    |> Regex.replace(branch, "-")
    |> String.trim("-")
  end

  @doc "Human-readable description of the sprite name rule."
  @spec sprite_name_rule() :: String.t()
  def sprite_name_rule, do: @sprite_name_rule

  @doc """
  Whether `name` (an expanded sprite name) is valid: it matches
  `#{inspect(@sprite_name.source)}`. The rule is lowercase-only, so names
  that differ only by case can never alias the same VM.
  """
  @spec valid_sprite_name?(String.t()) :: boolean()
  def valid_sprite_name?(name) when is_binary(name), do: Regex.match?(@sprite_name, name)

  @doc """
  Whether the literal parts of a sprite name template can form a valid
  sprite name. Each placeholder is treated as one valid character (the
  shortest value it can expand to), so a template whose literal text is
  invalid, starts with a hyphen, or is already longer than 63 characters is
  rejected when the recipe is saved. The expanded name is checked again
  with `valid_sprite_name?/1`.
  """
  @spec valid_name_template?(String.t()) :: boolean()
  def valid_name_template?(template) when is_binary(template) do
    @token |> Regex.replace(template, "a") |> valid_sprite_name?()
  end

  defp placeholders(string) do
    @token
    |> Regex.scan(string, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp blank?(value), do: value in [nil, ""]
end
