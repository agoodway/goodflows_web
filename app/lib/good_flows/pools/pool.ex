defmodule GoodFlows.Pools.Pool do
  @moduledoc """
  A project's pool of pre-built Sprite VMs ("members"), addressed by `slug`
  within its project.

  Each member runs the pool `setup` list once, then a checkpoint of it
  becomes the member's golden state, restored after every lease. A body may
  only set `slug`, `setup`, `min_ready`, `max_members`, and `idle_ttl_ms`;
  the project and account come from the URL. `setup` follows the recipe phase-list rules (at
  most 500 non-blank strings of at most 10,000 characters) and additionally
  allows no `{{…}}` placeholders and no host steps.

  `idle_ttl_ms` (optional, default `null`: off) opts the pool into idle
  shrink: idle members beyond `min_ready` plus unmet session demand are
  retired once they have been idle that long (at least 60,000 ms, at most
  30 days).

  `setup_version` starts at 1 and is bumped by `GoodFlows.Pools` whenever a
  replacement changes `setup`. `deleting_at` marks a pool whose deletion is
  in progress: it is invisible to reads and its slug is free again.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.Account
  alias GoodFlows.ChangesetErrors
  alias GoodFlows.Pools.{Config, Member}
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @allowed_keys ~w(slug setup min_ready max_members idle_ttl_ms)
  @idle_ttl_min_ms 60_000
  @idle_ttl_max_ms 30 * 24 * 60 * 60_000
  @max_items 500
  @max_line_length 10_000
  @placeholder ~r/\{\{.*?\}\}/s

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pools" do
    field :slug, :string
    field :setup, {:array, :string}, default: []
    field :min_ready, :integer, default: 1
    field :max_members, :integer
    field :setup_version, :integer, default: 1
    field :deleting_at, :utc_datetime_usec
    field :provision_failures, :integer, default: 0
    field :next_provision_at, :utc_datetime_usec
    field :last_provision_error, :string
    field :idle_ttl_ms, :integer
    field :member_counts, :map, virtual: true, default: %{}
    field :status, :string, virtual: true

    belongs_to :account, Account
    belongs_to :project, Project
    has_many :members, Member

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The keys a create or replace body may contain."
  @spec allowed_keys() :: [String.t()]
  def allowed_keys, do: @allowed_keys

  @doc """
  Builds a full-replacement changeset from a request body: an omitted
  (or null) `setup` becomes `[]` and an omitted (or null) `min_ready`
  becomes 1. Any key other
  than #{Enum.map_join(@allowed_keys, ", ", &"`#{&1}`")} is an error on that
  key. `account_id`, `project_id`, and `setup_version` are never cast.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(pool, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    {setup, setup_errors} = validate_setup(Map.get(attrs, "setup"))

    values = %{
      "slug" => Map.get(attrs, "slug"),
      "setup" => setup,
      # An explicit null is the default, like an omitted key (and `setup`).
      "min_ready" => Map.get(attrs, "min_ready") || 1,
      "max_members" => Map.get(attrs, "max_members"),
      # Omitted or null: idle shrink is off.
      "idle_ttl_ms" => Map.get(attrs, "idle_ttl_ms")
    }

    pool
    |> cast(values, [:slug, :setup, :min_ready, :max_members, :idle_ttl_ms])
    |> validate_required([:slug, :max_members])
    |> ChangesetErrors.prepend(setup_errors)
    |> ChangesetErrors.prepend(
      ChangesetErrors.unknown_keys(attrs, @allowed_keys, "is not allowed in a pool body")
    )
    |> validate_length(:slug, min: 1, max: 64, count: :bytes)
    |> validate_format(:slug, ~r/\A[a-z0-9][a-z0-9_-]*\z/,
      message: "must be #{Project.slug_rule()}"
    )
    |> validate_number(:max_members,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: Config.max_members_cap()
    )
    |> validate_min_ready()
    |> validate_number(:idle_ttl_ms,
      greater_than_or_equal_to: @idle_ttl_min_ms,
      less_than_or_equal_to: @idle_ttl_max_ms
    )
    |> unique_constraint(:slug,
      name: :pools_project_id_slug_index,
      message: "has already been taken by another pool in this project"
    )
    |> foreign_key_constraint(:project_id, name: :pools_project_id_fkey)
  end

  defp validate_min_ready(changeset) do
    max = get_field(changeset, :max_members)

    changeset
    |> validate_number(:min_ready, greater_than_or_equal_to: 0)
    |> then(fn changeset ->
      if is_integer(max),
        do: validate_number(changeset, :min_ready, less_than_or_equal_to: max),
        else: changeset
    end)
  end

  defp validate_setup(nil), do: {[], []}

  defp validate_setup(items) when is_list(items) and length(items) > @max_items,
    do: {[], [{:setup, {"must have at most %{count} items", count: @max_items}}]}

  defp validate_setup(items) when is_list(items) do
    errors =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} -> item_errors(item, index) end)

    if errors == [], do: {items, []}, else: {[], errors}
  end

  defp validate_setup(_other), do: {[], [{:setup, {"must be a list of strings", []}}]}

  defp item_errors(item, index) when is_binary(item) do
    cond do
      String.trim(item) == "" ->
        [{field(index), {"can't be blank", validation: :required}}]

      String.length(item) > @max_line_length ->
        [
          {field(index),
           {"should be at most %{count} character(s)",
            count: @max_line_length, validation: :length, kind: :max, type: :string}}
        ]

      token = Regex.run(@placeholder, item) ->
        [
          {field(index),
           {"contains placeholder #{hd(token)}; pool setup cannot use placeholders",
            validation: :placeholder}}
        ]

      true ->
        []
    end
  end

  defp item_errors(_item, index),
    do: [{field(index), {"must be a string (host steps are not supported)", validation: :type}}]

  # Indexed keys stay strings so request data never creates atoms.
  defp field(index), do: "setup[#{index}]"
end
