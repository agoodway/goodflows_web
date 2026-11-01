defmodule GoodFlows.Spry.Recipe do
  @moduledoc """
  An account's Spry recipe: a sprite `name` template plus the in-VM shell
  lines for each lifecycle phase (`setup`, `start`, `stop`, `teardown`).

  Phase lists are validated from the raw params before casting so that host
  steps (`{host: …}` maps or any other non-string item) get an explicit error
  keyed by phase and index, e.g. `setup[2]`. Indexed error keys are strings,
  so arbitrary indexes never create atoms.

  Each phase list holds at most 500 items of at most 10,000 characters, and
  `name` is at most 255 characters.

  The `name` is the sprite name template, and it is unique per account: two
  recipes of an account can never share a template, so a recipe identifies
  the sprites it drives. Its literal text must be able to form a valid
  sprite name (`GoodFlows.Spry.Template.valid_name_template?/1`); the
  expanded name is checked again when a run is planned.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Spry.Template

  @type t :: %__MODULE__{}

  @phases [:setup, :start, :stop, :teardown]
  @max_items 500
  @max_line_length 10_000
  @max_name_length 255

  @host_step_message "host steps are not supported by the API"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "recipes" do
    field :name, :string
    field :setup, {:array, :string}, default: []
    field :start, {:array, :string}, default: []
    field :stop, {:array, :string}, default: []
    field :teardown, {:array, :string}, default: []

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The lifecycle phases a recipe defines."
  @spec phases() :: [atom()]
  def phases, do: @phases

  @doc """
  Builds a full-replacement changeset: omitted phase lists become empty
  lists and an omitted `name` is an error (even when replacing a recipe that
  already has one). Rejects `org`, host steps, blank items, and unknown
  placeholders.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(recipe, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    {phase_values, phase_errors} = validate_phases(attrs)

    recipe
    |> cast(Map.put(phase_values, "name", Map.get(attrs, "name")), [:name | @phases])
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name_length)
    |> add_errors(phase_errors)
    |> validate_no_org(attrs)
    |> validate_name_placeholders()
    |> validate_name_format()
    |> validate_line_placeholders(phase_values)
    |> unique_constraint(:name,
      name: :recipes_account_id_name_index,
      message: "has already been taken by another recipe in this account"
    )
  end

  defp validate_phases(attrs) do
    Enum.reduce(@phases, {%{}, []}, fn phase, {values, errors} ->
      key = Atom.to_string(phase)

      case validate_phase(phase, Map.get(attrs, key)) do
        {:ok, items} -> {Map.put(values, key, items), errors}
        {:error, phase_errors} -> {Map.put(values, key, []), errors ++ phase_errors}
      end
    end)
  end

  defp validate_phase(_phase, nil), do: {:ok, []}

  defp validate_phase(phase, items) when is_list(items) and length(items) > @max_items do
    {:error, [{phase, {"must have at most %{count} items", count: @max_items}}]}
  end

  defp validate_phase(phase, items) when is_list(items) do
    errors =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} -> item_errors(phase, item, index) end)

    if errors == [], do: {:ok, items}, else: {:error, errors}
  end

  defp validate_phase(phase, _other), do: {:error, [{phase, {"must be a list of strings", []}}]}

  defp item_errors(phase, item, index) when is_binary(item) do
    cond do
      String.trim(item) == "" ->
        [{item_field(phase, index), {"can't be blank", validation: :required}}]

      String.length(item) > @max_line_length ->
        [
          {item_field(phase, index),
           {"should be at most %{count} character(s)",
            count: @max_line_length, validation: :length, kind: :max, type: :string}}
        ]

      true ->
        []
    end
  end

  defp item_errors(phase, _item, index) do
    [{item_field(phase, index), {@host_step_message, validation: :host_step}}]
  end

  # Indexed error keys such as "setup[2]" are kept as strings: they render
  # identically in JSON (`traverse_errors/2` groups by any key) and never
  # create atoms from request data.
  defp item_field(phase, index), do: "#{phase}[#{index}]"

  # `Ecto.Changeset.add_error/4` is specced for atom keys, so errors are
  # prepended directly; atom and string keys are both supported downstream.
  defp add_errors(changeset, []), do: changeset

  defp add_errors(%Ecto.Changeset{errors: existing} = changeset, errors) do
    %{changeset | errors: Enum.reverse(errors) ++ existing, valid?: false}
  end

  defp validate_no_org(changeset, attrs) do
    if Map.has_key?(attrs, "org") do
      add_error(
        changeset,
        :org,
        "is not supported; the Sprites organization comes from the account's Sprites credential"
      )
    else
      changeset
    end
  end

  defp validate_name_placeholders(changeset) do
    validate_change(changeset, :name, fn :name, name ->
      case Template.scan(name, :name) do
        {:ok, _names} -> []
        {:error, {:unknown, unknown}} -> Enum.map(unknown, &name_placeholder_error/1)
      end
    end)
  end

  # Only checked once the placeholders are valid, so a name gets one clear
  # error at a time.
  defp validate_name_format(%Ecto.Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :name),
      do: changeset,
      else: validate_change(changeset, :name, &name_format_errors/2)
  end

  defp name_format_errors(:name, name) do
    if Template.valid_name_template?(name),
      do: [],
      else: [name: {"must form a valid sprite name (#{Template.sprite_name_rule()})", []}]
  end

  defp name_placeholder_error("sprite") do
    {:name,
     {"cannot use {{sprite}}: the sprite name cannot refer to itself", placeholder: "sprite"}}
  end

  defp name_placeholder_error(placeholder) do
    {:name, {"contains unknown placeholder {{%{placeholder}}}", placeholder: placeholder}}
  end

  defp validate_line_placeholders(changeset, phase_values) do
    errors =
      for phase <- @phases,
          {line, index} <- Enum.with_index(Map.fetch!(phase_values, Atom.to_string(phase))),
          {:error, {:unknown, unknown}} <- [Template.scan(line, :step)],
          placeholder <- unknown do
        {item_field(phase, index),
         {"contains unknown placeholder {{%{placeholder}}} in %{phase}",
          placeholder: placeholder, phase: phase}}
      end

    add_errors(changeset, errors)
  end
end
