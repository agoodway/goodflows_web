defmodule GoodFlows.Projects do
  @moduledoc """
  Account-owned projects addressed by slug. Every function takes the owning
  account; another account's project is reported as `:not_found`.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo

  @doc "Lists the account's projects ordered by slug."
  @spec list_projects(Account.t()) :: [Project.t()]
  def list_projects(%Account{id: account_id}) do
    Project
    |> where(account_id: ^account_id)
    |> order_by([p], asc: p.slug)
    |> Repo.all()
  end

  @doc "Fetches the account's project with `slug`."
  @spec get_project(Account.t(), term()) :: {:ok, Project.t()} | {:error, :not_found}
  def get_project(%Account{id: account_id}, slug) when is_binary(slug) do
    case Repo.get_by(Project, account_id: account_id, slug: slug) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :not_found}
    end
  end

  def get_project(%Account{}, _slug), do: {:error, :not_found}

  @doc "Creates a project for the account."
  @spec create_project(Account.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(%Account{id: account_id}, attrs) do
    %Project{account_id: account_id}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a project that has no recipes. Returns `{:error, :has_recipes}`
  while any recipe belongs to it, including one committed concurrently
  (the foreign key violation maps through `no_assoc_constraint/3`).
  """
  @spec delete_project(Account.t(), Project.t()) ::
          :ok | {:error, :not_found | :has_recipes}
  def delete_project(%Account{id: account_id}, %Project{account_id: account_id} = project) do
    case project |> Project.delete_changeset() |> Repo.delete(stale_error_field: :id) do
      {:ok, _project} ->
        :ok

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :recipes),
          do: {:error, :has_recipes},
          else: {:error, :not_found}
    end
  end

  def delete_project(%Account{}, %Project{}), do: {:error, :not_found}
end
