defmodule GoodFlows.Spry.Plan do
  @moduledoc """
  Pure run planning shared by dry runs, run admission, and the worker.

  `build/2` validates a run request against a recipe and expands the sprite
  name and every line of the requested phase, so all placeholder errors are
  reported before anything is created or executed. `with_vm_state/2` then
  decides the VM actions (`create`, `exec`, `destroy`) given whether the
  sprite exists.

  Inputs are substituted unquoted into shell lines, so each is restricted to
  a conservative character set and length (see `input_rules/0`); a
  violation is a `422` on that field. Recipes should prefer
  `{{branch_slug}}` over `{{branch}}` wherever a value reaches a name or a
  path. The expanded sprite name must satisfy
  `GoodFlows.Spry.Template.valid_sprite_name?/1`.
  """
  import Ecto.Changeset

  alias GoodFlows.Spry.{Recipe, Run, Template}

  @phases ~w(setup start stop teardown)

  @types %{
    phase: :string,
    branch: :string,
    commit: :string,
    remote: :string,
    sprite: :string,
    no_create: :boolean,
    no_destroy: :boolean,
    dry_run: :boolean
  }

  @cast_fields Map.keys(@types)
  @computed_types %{sprite_name: :string, commands: {:array, :string}}

  # Every input must start with a letter or digit (so it can never be read
  # as a command-line option) and contain no shell metacharacters.
  @input_rules %{
    branch:
      {~r/\A[A-Za-z0-9][A-Za-z0-9._\/+-]*\z/, 255,
       "letters, digits, and . _ / + -, starting with a letter or digit"},
    commit:
      {~r/\A[A-Za-z0-9][A-Za-z0-9._\/+-]*\z/, 255,
       "letters, digits, and . _ / + -, starting with a letter or digit"},
    remote:
      {~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@%+-]*\z/, 1024,
       "letters, digits, and . _ : / @ % + -, starting with a letter or digit"}
  }
  @max_sprite_template_length 255

  @placeholder_fields %{
    "branch" => :branch,
    "branch_slug" => :branch,
    "commit" => :commit,
    "remote" => :remote
  }

  @enforce_keys [:phase, :sprite_name, :commands]
  defstruct [
    :phase,
    :sprite_name,
    :commands,
    inputs: %{},
    no_create: false,
    no_destroy: false,
    dry_run: false
  ]

  @type t :: %__MODULE__{
          phase: String.t(),
          sprite_name: String.t(),
          commands: [String.t()],
          inputs: %{optional(String.t()) => String.t() | nil},
          no_create: boolean(),
          no_destroy: boolean(),
          dry_run: boolean()
        }

  @type action :: %{kind: String.t(), command: String.t()}

  @doc """
  Validates `params` (phase, flags, and inputs) and expands the recipe's
  name (or the `sprite` override) and the phase's lines.

  `dry_run` is cast with the other flags (so `"true"`, `"1"`, and `true` all
  mean a dry run); callers decide dry-run vs real run from `plan.dry_run`
  only, never from the raw params.

  Returns `{:error, changeset}` with errors keyed by request field.
  """
  @spec build(Recipe.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def build(%Recipe{} = recipe, params) when is_map(params) do
    {%{}, Map.merge(@types, @computed_types)}
    |> cast(params, @cast_fields)
    |> validate_required([:phase])
    |> validate_inclusion(:phase, @phases)
    |> validate_flag(:no_create, "setup")
    |> validate_flag(:no_destroy, "teardown")
    |> validate_inputs()
    |> validate_sprite_override()
    |> expand(recipe)
    |> apply_action(:plan)
    |> case do
      {:ok, data} -> {:ok, to_plan(data)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp to_plan(data) do
    %__MODULE__{
      phase: data.phase,
      sprite_name: data.sprite_name,
      commands: data.commands,
      inputs: %{
        "branch" => data[:branch],
        "commit" => data[:commit],
        "remote" => data[:remote],
        "sprite" => data[:sprite]
      },
      no_create: data[:no_create] == true,
      no_destroy: data[:no_destroy] == true,
      dry_run: data[:dry_run] == true
    }
  end

  @doc "Rebuilds the plan stored on an admitted run."
  @spec from_run(Run.t()) :: t()
  def from_run(%Run{} = run) do
    %__MODULE__{
      phase: run.phase,
      sprite_name: Map.fetch!(run.plan, "sprite_name"),
      commands: Map.fetch!(run.plan, "commands"),
      inputs: run.inputs,
      no_create: run.no_create,
      no_destroy: run.no_destroy
    }
  end

  @doc "The JSON snapshot persisted on a run."
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = plan) do
    %{"phase" => plan.phase, "sprite_name" => plan.sprite_name, "commands" => plan.commands}
  end

  @doc """
  Adds the VM actions that depend on whether the sprite exists:

    * setup creates a missing VM unless `no_create` is set
    * start, stop, and teardown require an existing VM
    * teardown destroys the VM afterwards unless `no_destroy` is set
  """
  @spec with_vm_state(t(), boolean()) :: {:ok, [action()]} | {:error, String.t()}
  def with_vm_state(%__MODULE__{} = plan, exists?) when is_boolean(exists?) do
    execs = Enum.map(plan.commands, &%{kind: "exec", command: &1})
    name = plan.sprite_name

    case {plan.phase, exists?} do
      {"setup", true} ->
        {:ok, execs}

      {"setup", false} when plan.no_create ->
        {:error, "sprite #{name} does not exist and no_create is set"}

      {"setup", false} ->
        {:ok, [%{kind: "create", command: "create #{name}"} | execs]}

      {_phase, false} ->
        {:error, "sprite #{name} does not exist"}

      {"teardown", true} when plan.no_destroy ->
        {:ok, execs}

      {"teardown", true} ->
        {:ok, execs ++ [%{kind: "destroy", command: "destroy #{name}"}]}

      {_phase, true} ->
        {:ok, execs}
    end
  end

  defp validate_flag(changeset, flag, phase) do
    if get_field(changeset, flag) == true and get_field(changeset, :phase) != phase do
      add_error(changeset, flag, "is only allowed with phase %{phase}", phase: phase)
    else
      changeset
    end
  end

  @doc """
  The allowed format of each run input: `{regex, max_length, description}`.
  """
  @spec input_rules() :: %{atom() => {Regex.t(), pos_integer(), String.t()}}
  def input_rules, do: @input_rules

  defp validate_inputs(changeset) do
    Enum.reduce(@input_rules, changeset, fn {field, {regex, max, description}}, acc ->
      acc
      |> validate_length(field, max: max)
      |> validate_format(field, regex, message: "must be #{description}")
    end)
  end

  defp validate_sprite_override(changeset) do
    changeset
    |> validate_length(:sprite, max: @max_sprite_template_length)
    |> validate_change(:sprite, &sprite_override_errors/2)
  end

  defp sprite_override_errors(:sprite, sprite) do
    case Template.scan(sprite, :name) do
      {:ok, _names} -> sprite_override_format_errors(sprite)
      {:error, {:unknown, unknown}} -> Enum.map(unknown, &unknown_override_error/1)
    end
  end

  defp sprite_override_format_errors(sprite) do
    if Template.valid_name_template?(sprite) do
      []
    else
      [sprite: "must form a valid sprite name (#{Template.sprite_name_rule()})"]
    end
  end

  defp unknown_override_error(placeholder) do
    {:sprite, {"contains unknown placeholder {{%{placeholder}}}", placeholder: placeholder}}
  end

  defp expand(%Ecto.Changeset{valid?: false} = changeset, _recipe), do: changeset

  defp expand(changeset, recipe) do
    phase = get_field(changeset, :phase)
    branch = get_field(changeset, :branch)

    values = %{
      "branch" => branch,
      "branch_slug" => branch && Template.slug(branch),
      "commit" => get_field(changeset, :commit),
      "remote" => get_field(changeset, :remote)
    }

    template = get_field(changeset, :sprite) || recipe.name

    with {:ok, name} <- expand_name(template, values),
         {:ok, commands} <- expand_lines(recipe, phase, Map.put(values, "sprite", name)) do
      changeset
      |> put_change(:sprite_name, name)
      |> put_change(:commands, commands)
    else
      {:error, {field, message, opts}} -> add_error(changeset, field, message, opts)
    end
  end

  defp expand_name(template, values) do
    case Template.expand(template, values) do
      {:ok, name} ->
        cond do
          String.contains?(name, "/") ->
            {:error,
             {:sprite_name,
              "expands to %{name}, which contains \"/\"; use {{branch_slug}} instead of {{branch}}",
              name: name}}

          not Template.valid_sprite_name?(name) ->
            {:error,
             {:sprite_name, "expands to %{name}, which is not a valid sprite name (%{rule})",
              name: name, rule: Template.sprite_name_rule()}}

          true ->
            {:ok, name}
        end

      {:error, {:missing, placeholder}} ->
        missing_error(placeholder, "the sprite name")
    end
  end

  defp expand_lines(recipe, phase, values) do
    recipe
    |> Map.fetch!(String.to_existing_atom(phase))
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {line, index}, {:ok, acc} ->
      case Template.expand(line, values) do
        {:ok, expanded} ->
          {:cont, {:ok, [expanded | acc]}}

        {:error, {:missing, placeholder}} ->
          {:halt, missing_error(placeholder, "#{phase}[#{index}]")}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      error -> error
    end
  end

  defp missing_error(placeholder, location) do
    field = Map.get(@placeholder_fields, placeholder, :phase)

    {:error,
     {field, "is required to expand {{%{placeholder}}} in %{location}",
      placeholder: placeholder, location: location}}
  end
end
