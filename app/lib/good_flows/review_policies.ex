defmodule GoodFlows.ReviewPolicies do
  @moduledoc """
  Versioned `review-policy/1` documents per project (the `review-policy`
  capability).

  A project that never wrote a policy has version 0
  (`GoodFlows.ReviewPolicies.Document.default/0`), which is never stored.
  `write/4` stores version `n + 1` when the body names the current version
  `n` as `previous_version`, under a row lock on the project, so two
  concurrent writes on the same version give one new version and one
  `:policy_version_conflict`. A retry (`previous_version` one below the
  current version, with the current version's `policy` and `note`) returns
  the current version. Only owners and admins write.

  A new version recomputes the verdict of every `draft` and `open` change
  request of the project in the same transaction
  (`GoodFlows.ChangeRequests.recompute_after_policy_write/1`).
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests
  alias GoodFlows.JsonDocument
  alias GoodFlows.KeysetCursor
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.ReviewPolicies.{Document, Glob, Version}

  @default_page_size 50
  @max_page_size 200

  @typedoc "One page of versions; `next_cursor` is nil on the last page."
  @type page :: %{versions: [Version.t()], next_cursor: String.t() | nil}

  @doc "The project's current version: the newest stored one, or version 0."
  @spec current(Project.t() | Ecto.UUID.t()) :: Version.t()
  def current(%Project{id: id}), do: current(id)

  def current(project_id) when is_binary(project_id) do
    Version
    |> where(project_id: ^project_id)
    |> order_by(desc: :version)
    |> limit(1)
    |> preload(:account_user)
    |> Repo.one()
    |> case do
      nil -> version_zero(project_id)
      version -> version
    end
  end

  defp version_zero(project_id),
    do: %Version{project_id: project_id, version: 0, document: Document.default()}

  @doc """
  The current version compiled for verdicts: its number, the effective
  document, each `paths` glob with its outcome and regex, and the
  `evidence.ignore_paths` regexes.
  """
  @spec compiled(Ecto.UUID.t()) :: GoodFlows.ChangeRequests.Rules.policy()
  def compiled(project_id) do
    version = current(project_id)
    compile(version.version, version.document)
  end

  @doc "Compiles policy `document` as version `number` (see `compiled/1`)."
  @spec compile(non_neg_integer(), map()) :: GoodFlows.ChangeRequests.Rules.policy()
  def compile(number, document) do
    effective = Document.effective(document)

    %{
      version: number,
      effective: effective,
      globs: Enum.map(effective["paths"], &{&1["glob"], &1["outcome"], Glob.compile(&1["glob"])}),
      ignore: Enum.map(effective["evidence"]["ignore_paths"], &Glob.compile/1)
    }
  end

  @doc "Version `number` of the project (0 is the default), or `:not_found`."
  @spec get_version(Project.t(), non_neg_integer()) :: {:ok, Version.t()} | {:error, :not_found}
  def get_version(%Project{id: id}, 0), do: {:ok, version_zero(id)}

  def get_version(%Project{id: id}, number) when is_integer(number) and number > 0 do
    case Repo.one(
           from v in Version,
             where: v.project_id == ^id and v.version == ^number,
             preload: :account_user
         ) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  def get_version(%Project{}, _number), do: {:error, :not_found}

  @doc """
  One page of stored versions, newest first. Params: `"limit"` (1 to
  #{@max_page_size}, default #{@default_page_size}) and `"cursor"` (the
  previous page's `next_cursor`). A bad value is a changeset error.
  """
  @spec list_versions(Project.t(), map()) :: {:ok, page()} | {:error, Ecto.Changeset.t()}
  def list_versions(%Project{id: id}, params) do
    with {:ok, %{limit: limit, cursor: cursor}} <- list_params(params) do
      versions =
        Version
        |> where(project_id: ^id)
        |> before_cursor(cursor)
        |> order_by(desc: :version)
        |> limit(^(limit + 1))
        |> preload(:account_user)
        |> Repo.all()

      {page, rest} = Enum.split(versions, limit)
      next = if rest != [], do: KeysetCursor.encode_integer(List.last(page).version)
      {:ok, %{versions: page, next_cursor: next}}
    end
  end

  defp before_cursor(query, nil), do: query
  defp before_cursor(query, version), do: where(query, [v], v.version < ^version)

  defp list_params(params),
    do: KeysetCursor.integer_page_params(params, @default_page_size, @max_page_size)

  @doc """
  Writes a new version from a normalized body. Returns `{:ok, :created,
  version}`, `{:ok, :retry, version}` for an exact retry, or an error:
  `:forbidden` (not an owner or admin), `{:invalid_body, errors}`,
  `:policy_version_conflict`, or `:not_found` when the project is gone.
  """
  @spec write(Project.t(), AccountUser.t(), ApiKey.t(), term()) ::
          {:ok, :created | :retry, Version.t()}
          | {:error, :forbidden | :not_found | :policy_version_conflict | {:invalid_body, map()}}
  def write(%Project{} = project, %AccountUser{} = account_user, %ApiKey{} = api_key, body) do
    with :ok <- require_admin(account_user),
         {:ok, write} <- validate(body) do
      Repo.transaction(fn -> write_locked(project, account_user, api_key, write) end)
      |> case do
        {:ok, {status, version}} -> {:ok, status, Repo.preload(version, :account_user)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp require_admin(account_user),
    do: if(AccountUser.admin?(account_user), do: :ok, else: {:error, :forbidden})

  defp validate(body) do
    case Document.validate_write(body) do
      {:ok, write} -> {:ok, write}
      {:error, errors} -> {:error, {:invalid_body, GoodFlows.DocumentErrors.render(errors)}}
    end
  end

  defp write_locked(project, account_user, api_key, write) do
    lock = from p in Project, where: p.id == ^project.id, lock: "FOR NO KEY UPDATE", select: p.id
    if Repo.one(lock) == nil, do: Repo.rollback(:not_found)

    current = current(project.id)

    cond do
      write.previous_version == current.version ->
        version =
          %Version{}
          |> Version.changeset(%{
            project_id: project.id,
            version: current.version + 1,
            previous_version: current.version,
            document: write.policy,
            note: write.note,
            account_user_id: account_user.id,
            api_key_id: api_key.id
          })
          |> Repo.insert!()

        ChangeRequests.recompute_after_policy_write(project)

        ProjectEvents.record(
          project.id,
          nil,
          "policy_version_created",
          %{"version" => version.version, "note" => version.note},
          api_key
        )

        {:created, version}

      retry?(write, current) ->
        {:retry, current}

      true ->
        Repo.rollback(:policy_version_conflict)
    end
  end

  defp retry?(write, %Version{version: version} = current) when version > 0 do
    write.previous_version == version - 1 and write.note == current.note and
      JsonDocument.digest(write.policy) == JsonDocument.digest(current.document)
  end

  defp retry?(_write, _current), do: false
end
