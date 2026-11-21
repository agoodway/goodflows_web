defmodule GoodFlows.FeatureIndex do
  @moduledoc """
  The per-project feature index (the `feature-index` capability): the
  verify skill's features, each with an `id`, a `title` and `paths` globs,
  synced as immutable versions.

  `sync/4` validates `{"features": [...]}` (1 to 500 entries; `id`
  matching `[a-z0-9][a-z0-9_-]{0,63}` and unique, `title` 1 to 200
  characters, `paths` 1 to 100 globs of 1 to 512 bytes under the review
  policy glob rules) and stores the next version, or answers `:duplicate`
  when the features equal the newest version's as a JSON value. A new
  version recomputes every `draft` and `open` change request of the
  project in the same transaction.

  `map_files/3` maps a head's `git-facts` diff files to features.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.ChangeRequests
  alias GoodFlows.DocumentErrors
  alias GoodFlows.FeatureIndex.Version
  alias GoodFlows.JsonDocument
  alias GoodFlows.KeysetCursor
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.ReviewPolicies.Glob
  alias GoodFlows.TestReports.Shape

  @id ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @default_page_size 50
  @max_page_size 200

  @typedoc "A compiled index: its version and each feature's ID and glob regexes."
  @type compiled :: %{version: pos_integer(), features: [{String.t(), [Regex.t()]}]}

  @typedoc "Changed files mapped to features."
  @type mapping :: %{unmapped: [String.t()], features: [String.t()]}

  @doc """
  Stores a new version from a normalized body. Returns `{:ok, :created,
  version}`, `{:ok, :duplicate, version}` or `{:invalid_body, errors}`.
  """
  @spec sync(Project.t(), ApiKey.t(), term()) ::
          {:ok, :created | :duplicate, Version.t()}
          | {:error, :not_found | {:invalid_body, DocumentErrors.errors()}}
  def sync(%Project{} = project, %ApiKey{} = api_key, body) do
    with {:ok, features} <- validate(body) do
      Repo.transaction(fn -> sync_locked(project, api_key, features) end)
      |> case do
        {:ok, {status, version}} -> {:ok, status, version}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Validates a sync body and returns its features."
  @spec validate(term()) :: {:ok, [map()]} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def validate(body) do
    feature =
      {:object,
       %{
         "id" => {:string, format: @id},
         "title" => {:fun, &title_errors/2, :title},
         "paths" => {:list, {:fun, &glob_errors/2, :glob}, min: 1, max: 100}
       }}

    spec = {:object, %{"features" => {:list, feature, min: 1, max: 500}}}

    errors =
      case Shape.check(body, spec, []) do
        [] ->
          ids = Enum.map(body["features"], & &1["id"])

          if length(Enum.uniq(ids)) == length(ids),
            do: [],
            else: [{["features"], "must not repeat a feature id"}]

        errors ->
          errors
      end

    case errors do
      [] ->
        {:ok, body["features"]}

      errors ->
        cut = Enum.map(errors, fn {path, m} -> {Enum.take_while(path, &is_binary/1), m} end)
        {:error, {:invalid_body, DocumentErrors.render(cut)}}
    end
  end

  defp title_errors(value, path) do
    if is_binary(value) and String.length(value) in 1..200,
      do: [],
      else: [{path, "must be a string of 1 to 200 characters"}]
  end

  defp glob_errors(value, path) when is_binary(value) and byte_size(value) > 512,
    do: [{path, "is too long"}]

  defp glob_errors(value, path) do
    case Glob.error(value) do
      nil -> []
      message -> [{path, message}]
    end
  end

  defp sync_locked(project, api_key, features) do
    lock = from p in Project, where: p.id == ^project.id, lock: "FOR UPDATE", select: p.id
    if Repo.one(lock) == nil, do: Repo.rollback(:not_found)

    digest = JsonDocument.digest(features)

    case newest(project.id) do
      %Version{digest: ^digest} = current ->
        {:duplicate, current}

      current ->
        version =
          Repo.insert!(%Version{
            project_id: project.id,
            version: if(current, do: current.version + 1, else: 1),
            features: features,
            digest: digest,
            account_user_id: api_key.account_user_id,
            api_key_id: api_key.id
          })

        ChangeRequests.recompute_after_policy_write(project)
        {:created, version}
    end
  end

  defp newest(project_id) do
    Repo.one(
      from v in Version,
        where: v.project_id == ^project_id,
        order_by: [desc: v.version],
        limit: 1
    )
  end

  @doc "The current version, or `:not_found` when the project never synced."
  @spec current(Project.t()) :: {:ok, Version.t()} | {:error, :not_found}
  def current(%Project{id: id}) do
    case newest(id) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc "Version `number`, or `:not_found`."
  @spec get_version(Project.t(), pos_integer()) :: {:ok, Version.t()} | {:error, :not_found}
  def get_version(%Project{id: id}, number) do
    case Repo.get_by(Version, project_id: id, version: number) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc """
  One page of versions, newest first. Params: `"limit"` (1 to
  #{@max_page_size}, default #{@default_page_size}) and `"cursor"`.
  """
  @spec list_versions(Project.t(), map()) ::
          {:ok, %{versions: [Version.t()], next_cursor: String.t() | nil}}
          | {:error, Ecto.Changeset.t()}
  def list_versions(%Project{id: id}, params) do
    with {:ok, %{limit: limit, cursor: cursor}} <-
           KeysetCursor.integer_page_params(params, @default_page_size, @max_page_size) do
      versions =
        Version
        |> where(project_id: ^id)
        |> then(&if cursor, do: where(&1, [v], v.version < ^cursor), else: &1)
        |> order_by(desc: :version)
        |> limit(^(limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(versions, limit)
      next = if rest != [], do: KeysetCursor.encode_integer(List.last(page).version)
      {:ok, %{versions: page, next_cursor: next}}
    end
  end

  @doc "The project's current index compiled for verdicts, or nil."
  @spec compiled(Ecto.UUID.t()) :: compiled() | nil
  def compiled(project_id) do
    case newest(project_id) do
      nil ->
        nil

      version ->
        %{
          version: version.version,
          features:
            Enum.map(version.features, fn f ->
              {f["id"], Enum.map(f["paths"], &Glob.compile/1)}
            end)
        }
    end
  end

  @doc """
  Maps `git-facts` diff `files` to `features`: each file maps to every
  feature with a glob matching its `path` or `old_path`. Files that are
  `ignored?/2` are left out. Returns the unmapped paths and the mapped
  feature IDs, both sorted.
  """
  @spec map_files([map()], [{String.t(), [Regex.t()]}], [Regex.t()]) :: mapping()
  def map_files(files, features, ignore) do
    files = Enum.reject(files, &ignored?(&1, ignore))

    {unmapped, mapped} =
      Enum.reduce(files, {[], MapSet.new()}, fn file, {unmapped, mapped} ->
        ids = for {id, regexes} <- features, any_match?(regexes, paths(file)), do: id

        if ids == [],
          do: {[file["path"] | unmapped], mapped},
          else: {unmapped, MapSet.union(mapped, MapSet.new(ids))}
      end)

    %{unmapped: unmapped |> Enum.uniq() |> Enum.sort(), features: Enum.sort(mapped)}
  end

  @doc """
  Whether a `git-facts` file matches `evidence.ignore_paths`: its `path`
  and, for a rename or copy, its `old_path` must each match an `ignore`
  regex.
  """
  @spec ignored?(map(), [Regex.t()]) :: boolean()
  def ignored?(file, ignore),
    do: Enum.all?(paths(file), fn path -> Enum.any?(ignore, &Glob.match?(&1, path)) end)

  defp paths(file), do: Enum.filter([file["path"], file["old_path"]], &is_binary/1)

  defp any_match?(regexes, paths),
    do: Enum.any?(for regex <- regexes, path <- paths, do: Glob.match?(regex, path))
end
