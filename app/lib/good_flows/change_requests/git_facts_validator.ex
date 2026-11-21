defmodule GoodFlows.ChangeRequests.GitFactsValidator do
  @moduledoc """
  Validates a `git-facts/1` document (design D3) against its change
  request's `target_branch`.

  The document has only `format`, `head`, `target` (`branch`,
  `merge_base`), `commits` (oldest first, each `sha`, `parents` and
  `changed_files`) and `diff` (`files`). SHAs are 40 or 64 lowercase hex
  characters. File entries have `path`, `status`, nonnegative `additions`
  and `deletions`, and `old_path` exactly when `status` is `renamed` or
  `copied`. Paths are 1 to 4,096 bytes, relative, without control
  characters, and unique within their list. There are at most 1,000
  commits, 10,000 `diff.files` and 10,000 `changed_files` per commit.

  When the structure is valid, `target.branch` must equal the change
  request's `target_branch`, and `commits` must end at `head` (it may be
  empty only when `head` equals `target.merge_base`).
  """

  alias GoodFlows.ChangeRequests.Params
  alias GoodFlows.DocumentErrors
  alias GoodFlows.TestReports.Shape

  @format "git-facts/1"
  @statuses ~w(added modified deleted renamed copied type_changed)
  @with_old_path ~w(renamed copied)
  @max_commits 1_000
  @max_files 10_000
  @max_path_bytes 4_096

  @doc "The commit limit."
  @spec max_commits() :: pos_integer()
  def max_commits, do: @max_commits

  @doc "The file-list limit (`diff.files` and each commit's `changed_files`)."
  @spec max_files() :: pos_integer()
  def max_files, do: @max_files

  @doc "Validates `document` for a change request targeting `target_branch`."
  @spec validate(term(), String.t()) ::
          {:ok, map()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def validate(document, target_branch) do
    errors =
      case Shape.check(document, spec(), []) do
        [] -> cross_errors(document, target_branch)
        errors -> errors
      end

    if errors == [],
      do: {:ok, document},
      else: {:error, {:invalid_body, DocumentErrors.render(errors)}}
  end

  defp spec do
    {:object,
     %{
       "format" => {:enum, [@format]},
       "head" => Params.sha_spec(),
       "target" => {:object, %{"branch" => Params.text(), "merge_base" => Params.sha_spec()}},
       "commits" => {:list, commit_spec(), max: @max_commits},
       "diff" => {:object, %{"files" => files_spec()}}
     }}
  end

  defp commit_spec do
    {:object,
     %{
       "sha" => Params.sha_spec(),
       "parents" => {:fun, &parents_errors/2, :parents},
       "changed_files" => files_spec()
     }}
  end

  defp files_spec, do: {:fun, &files_errors/2, :files}

  defp file_spec do
    {:object,
     %{
       "path" => path_spec(),
       "status" => {:enum, @statuses},
       "additions" => {:int, 0},
       "deletions" => {:int, 0},
       "old_path" => {:omit, path_spec()}
     }}
  end

  defp path_spec, do: {:fun, &path_errors/2, :path}

  defp parents_errors([_ | _] = parents, path) do
    if Enum.all?(parents, &Params.sha?/1),
      do: [],
      else: [{path, "must hold SHAs"}]
  end

  defp parents_errors([], path), do: [{path, "must not be empty"}]
  defp parents_errors(_value, path), do: [{path, "must be an array"}]

  defp path_errors(value, path) do
    case Shape.check_into(
           value,
           {:string, min: 1, max: @max_path_bytes, no_control: true},
           path,
           []
         ) do
      [] -> if String.starts_with?(value, "/"), do: [{path, "must be relative"}], else: []
      errors -> errors
    end
  end

  # Errors carry reversed paths here, as `Shape` funs must return.
  defp files_errors(value, path) do
    case Shape.check_into(value, {:list, file_spec(), max: @max_files}, path, []) do
      [] -> old_path_errors(value, path) ++ duplicate_errors(value, path)
      errors -> errors ++ old_path_errors(value, path)
    end
  end

  defp old_path_errors(files, path) when is_list(files) do
    files
    |> Enum.with_index()
    |> Enum.flat_map(fn {file, index} -> old_path_error(file, ["old_path", index | path]) end)
  end

  defp old_path_errors(_files, _path), do: []

  defp old_path_error(%{"status" => status} = file, path) when status in @with_old_path do
    if Map.has_key?(file, "old_path"), do: [], else: [{path, "is required"}]
  end

  defp old_path_error(%{"status" => status, "old_path" => _}, path) when status in @statuses,
    do: [{path, "is only allowed for renamed and copied files"}]

  defp old_path_error(_file, _path), do: []

  defp duplicate_errors(files, path) do
    paths = Enum.map(files, & &1["path"])

    if length(Enum.uniq(paths)) == length(paths),
      do: [],
      else: [{path, "must not list a path twice"}]
  end

  defp cross_errors(document, target_branch) do
    branch_errors =
      if document["target"]["branch"] == target_branch,
        do: [],
        else: [{["target", "branch"], "must equal the change request's target_branch"}]

    branch_errors ++ commits_errors(document)
  end

  defp commits_errors(%{"commits" => [], "head" => head, "target" => %{"merge_base" => head}}),
    do: []

  defp commits_errors(%{"commits" => []}),
    do: [{["commits"], "must not be empty unless head is the merge base"}]

  defp commits_errors(%{"commits" => commits, "head" => head}) do
    if List.last(commits)["sha"] == head,
      do: [],
      else: [{["commits"], "must end with the head commit"}]
  end
end
