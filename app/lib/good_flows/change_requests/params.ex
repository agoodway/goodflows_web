defmodule GoodFlows.ChangeRequests.Params do
  @moduledoc """
  Validates change request create and merge bodies (normalized JSON from
  `GoodFlowsWeb.Plugs.JsonBody`).

  Create accepts only `title` (required), `source_branch` (required),
  `target_branch`, `change_id` and `links`. Titles and branches are
  1 to 256 UTF-8 bytes without control characters, `change_id` is
  one 1 to 64 byte slug matching `[a-z0-9][a-z0-9-]*`, and `links` is the
  workflow-run `links` shape. Merge accepts only `merged_commit` (40 or 64
  lowercase hex characters), `target_branch` and an optional string
  `lease_id`. A lease acquire accepts only `head` and `base` (SHAs), a
  parent link only `number` (a positive integer), a dependencies update
  only `change_ids` (at most 50 distinct `change_id` slugs) and a
  retarget only `target_branch`. Values are never rewritten. Errors are
  rendered by `GoodFlows.DocumentErrors`.
  """

  alias GoodFlows.DocumentErrors
  alias GoodFlows.TestReports.Shape
  alias GoodFlows.WorkflowRuns.Validator, as: RunValidator

  @slug ~r/\A[a-z0-9][a-z0-9-]*\z/
  @max_dependencies 50
  @sha ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @typedoc "Validated create attributes; `target_branch` is absent when not sent."
  @type create :: %{
          required(:title) => String.t(),
          required(:source_branch) => String.t(),
          optional(:target_branch) => String.t(),
          required(:change_id) => String.t() | nil,
          required(:links) => map() | nil
        }

  @doc "Validates a create body."
  @spec create(term()) :: {:ok, create()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def create(body) do
    spec =
      {:object,
       %{
         "title" => text(),
         "source_branch" => text(),
         "target_branch" => {:omit, text()},
         "change_id" => {:omit, change_id_spec()},
         "links" => {:omit, RunValidator.links_spec()}
       }}

    links_errors = if is_map(body), do: RunValidator.links_errors(body), else: []

    case Shape.check(body, spec, []) ++ links_errors do
      [] ->
        attrs = %{
          title: body["title"],
          source_branch: body["source_branch"],
          change_id: Map.get(body, "change_id"),
          links: Map.get(body, "links")
        }

        {:ok, put_present(attrs, :target_branch, Map.get(body, "target_branch"))}

      errors ->
        {:error, {:invalid_body, DocumentErrors.render(errors)}}
    end
  end

  @doc "Validates a merge report body; `lease_id` is nil when not sent."
  @spec merge(term()) ::
          {:ok,
           %{merged_commit: String.t(), target_branch: String.t(), lease_id: String.t() | nil}}
          | {:error, {:invalid_body, DocumentErrors.errors()}}
  def merge(body) do
    spec =
      {:object,
       %{
         "merged_commit" => {:string, format: @sha},
         "target_branch" => text(),
         "lease_id" => {:omit, {:string, []}}
       }}

    with :ok <- check(body, spec) do
      {:ok,
       %{
         merged_commit: body["merged_commit"],
         target_branch: body["target_branch"],
         lease_id: Map.get(body, "lease_id")
       }}
    end
  end

  @doc "Validates a merge lease acquire body."
  @spec acquire(term()) ::
          {:ok, %{head: String.t(), base: String.t()}}
          | {:error, {:invalid_body, DocumentErrors.errors()}}
  def acquire(body) do
    with :ok <- check(body, {:object, %{"head" => sha_spec(), "base" => sha_spec()}}),
         do: {:ok, %{head: body["head"], base: body["base"]}}
  end

  @doc "Validates a parent link body."
  @spec parent(term()) ::
          {:ok, pos_integer()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def parent(body) do
    with :ok <- check(body, {:object, %{"number" => {:int, 1}}}), do: {:ok, body["number"]}
  end

  @doc """
  Validates a dependencies body: `change_ids`, at most #{@max_dependencies}
  distinct slugs with the `change_id` rule, in the order given.
  """
  @spec dependencies(term()) ::
          {:ok, [String.t()]} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def dependencies(body) do
    spec =
      {:object, %{"change_ids" => {:list, change_id_spec(), max: @max_dependencies}}}

    with :ok <- check(body, spec) do
      ids = body["change_ids"]

      if Enum.uniq(ids) == ids,
        do: {:ok, ids},
        else: {:error, {:invalid_body, %{"change_ids" => ["must not repeat an id"]}}}
    end
  end

  @doc "Validates a retarget body."
  @spec retarget(term()) ::
          {:ok, String.t()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def retarget(body) do
    with :ok <- check(body, {:object, %{"target_branch" => text()}}),
         do: {:ok, body["target_branch"]}
  end

  defp change_id_spec, do: {:string, min: 1, max: 64, format: @slug}

  defp check(body, spec) do
    case Shape.check(body, spec, []) do
      [] -> :ok
      errors -> {:error, {:invalid_body, DocumentErrors.render(errors)}}
    end
  end

  @doc "Whether `value` is 40 or 64 lowercase hex characters."
  @spec sha?(term()) :: boolean()
  def sha?(value) when is_binary(value), do: Regex.match?(@sha, value)
  def sha?(_value), do: false

  @doc "The Shape spec of a SHA."
  @spec sha_spec() :: Shape.spec()
  def sha_spec, do: {:string, format: @sha}

  @doc "The Shape spec of a title or branch: 1 to 256 bytes, no control characters."
  @spec text() :: Shape.spec()
  def text, do: {:string, min: 1, max: 256, no_control: true}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
