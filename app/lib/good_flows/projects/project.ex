defmodule GoodFlows.Projects.Project do
  @moduledoc """
  An account-owned project addressed by its `slug`. A project groups the
  account's Spry recipes, uploaded test reports, and stored workflow runs;
  recipe names are unique within a project, and its cache entries and cache
  keys are deleted with it.

  `default_branch` names the project's fallback cache scope: the scope whose
  string equals it. It follows the cache scope rule
  (`GoodFlows.Caches.Rules`), defaults to `main`, and is not validated as a
  Git branch name. It is the only field that can be updated.

  The slug is 1 to 64 bytes matching `[a-z0-9][a-z0-9_-]*` and is unique
  within an account. There is no rename: the slug is the public name.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Caches.Rules
  alias GoodFlows.Spry.Recipe
  alias GoodFlows.TestReports.Report
  alias GoodFlows.WorkflowRuns.Run

  @type t :: %__MODULE__{}

  @slug_format ~r/\A[a-z0-9][a-z0-9_-]*\z/
  @max_slug_bytes 64

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :slug, :string
    field :default_branch, :string, default: "main"

    belongs_to :account, Account
    has_many :recipes, Recipe
    has_many :test_reports, Report
    has_many :workflow_runs, Run

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Human-readable description of the slug rule, for error messages."
  @spec slug_rule() :: String.t()
  def slug_rule,
    do:
      "1 to #{@max_slug_bytes} bytes of lowercase letters, digits, `_`, and `-`, " <>
        "starting with a letter or digit"

  @doc "Whether `slug` satisfies the project slug rule."
  @spec valid_slug?(term()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    byte_size(slug) in 1..@max_slug_bytes and Regex.match?(@slug_format, slug)
  end

  def valid_slug?(_slug), do: false

  @doc "Builds a changeset for creating a project."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:slug])
    |> cast_default_branch(attrs)
    |> validate_required([:slug])
    |> validate_length(:slug, min: 1, max: @max_slug_bytes, count: :bytes)
    |> validate_format(:slug, @slug_format, message: "must be #{slug_rule()}")
    |> unique_constraint(:slug,
      name: :projects_account_id_slug_index,
      message: "has already been taken by another project in this account"
    )
  end

  @doc "Builds a changeset that updates only `default_branch`."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(project, attrs) do
    project
    |> change()
    |> cast_default_branch(attrs)
  end

  # `empty_values: []`: the scope rule decides, so `""` is "must be …"
  # rather than silently dropped.
  defp cast_default_branch(changeset, attrs) do
    changeset
    |> cast(attrs, [:default_branch], empty_values: [])
    |> validate_required([:default_branch])
    |> validate_change(:default_branch, fn :default_branch, value ->
      if Rules.valid_scope?(value),
        do: [],
        else: [default_branch: "must be #{Rules.scope_rule()}"]
    end)
  end

  @doc """
  Builds the delete changeset; refuses while any recipe, test report, or
  workflow run belongs to the project.
  """
  @spec delete_changeset(t()) :: Ecto.Changeset.t()
  def delete_changeset(project) do
    project
    |> change()
    |> no_assoc_constraint(:recipes, name: :recipes_project_id_fkey)
    |> no_assoc_constraint(:test_reports, name: :test_reports_project_id_fkey)
    |> no_assoc_constraint(:workflow_runs, name: :workflow_runs_project_id_fkey)
  end
end
