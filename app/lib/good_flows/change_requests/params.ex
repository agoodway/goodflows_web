defmodule GoodFlows.ChangeRequests.Params do
  @moduledoc """
  Validates change request create and merge bodies (normalized JSON from
  `GoodFlowsWeb.Plugs.JsonBody`).

  Create accepts only `title` (required), `source_branch` (required),
  `target_branch`, `openspec_change` and `links`. Titles and branches are
  1 to 256 UTF-8 bytes without control characters, `openspec_change` is
  one 1 to 64 byte slug matching `[a-z0-9][a-z0-9-]*`, and `links` is the
  workflow-run `links` shape. Merge accepts only `merged_commit` (40 or 64
  lowercase hex characters), `target_branch` and an optional string
  `lease_id`. A lease acquire accepts only `head` and `base` (SHAs), a
  parent link only `number` (a positive integer) and a retarget only
  `target_branch`. Values are never rewritten. Errors are rendered by
  `GoodFlows.DocumentErrors`.
  """

  alias GoodFlows.DocumentErrors
  alias GoodFlows.TestReports.Shape
  alias GoodFlows.WorkflowRuns.Validator, as: RunValidator

  @slug ~r/\A[a-z0-9][a-z0-9-]*\z/
  @sha ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @typedoc "Validated create attributes; `target_branch` is absent when not sent."
  @type create :: %{
          required(:title) => String.t(),
          required(:source_branch) => String.t(),
          optional(:target_branch) => String.t(),
          required(:openspec_change) => String.t() | nil,
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
         "openspec_change" => {:omit, {:string, min: 1, max: 64, format: @slug}},
         "links" => {:omit, RunValidator.links_spec()}
       }}

    links_errors = if is_map(body), do: RunValidator.links_errors(body), else: []

    case Shape.check(body, spec, []) ++ links_errors do
      [] ->
        attrs = %{
          title: body["title"],
          source_branch: body["source_branch"],
          openspec_change: Map.get(body, "openspec_change"),
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

  @doc "Validates a retarget body."
  @spec retarget(term()) ::
          {:ok, String.t()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def retarget(body) do
    with :ok <- check(body, {:object, %{"target_branch" => text()}}),
         do: {:ok, body["target_branch"]}
  end

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
