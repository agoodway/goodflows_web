defmodule GoodFlows.WorkflowRunFixtures do
  @moduledoc """
  Decoded run-history documents for workflow-run storage tests.
  """

  alias GoodFlows.JsonDocument
  alias GoodFlows.Repo
  alias GoodFlows.WorkflowRuns.Run

  @dir Path.expand("workflow_runs", __DIR__)
  @golden Path.expand(
            "../../../../openspec/changes/archive/2026-11-09-add-workflow-run-storage/fixtures",
            __DIR__
          )
  @goodflows Path.expand("goodflows_workflow_runs", __DIR__)
  @graph String.duplicate("ab", 32)

  @doc """
  Names of the fixtures vendored from goodflows (see
  `goodflows_workflow_runs/README.md`).
  """
  @spec goodflows_names() :: [String.t()]
  def goodflows_names,
    do: ~w(full minimal child history-parent-default history-child-suite)

  @doc "The raw bytes of vendored goodflows fixture `name` (without `.json`)."
  @spec goodflows_json(String.t()) :: String.t()
  def goodflows_json(name) when is_binary(name),
    do: File.read!(Path.join(@goodflows, name <> ".json"))

  @doc "The decoded vendored goodflows fixture `name` (without `.json`)."
  @spec goodflows(String.t()) :: map()
  def goodflows(name) when is_binary(name) do
    {:ok, decoded} = JsonDocument.decode(goodflows_json(name))
    {:ok, normalized} = JsonDocument.normalize(decoded)
    normalized
  end

  @doc "The raw JSON of synthetic fixture `name` (without `.json`)."
  @spec json(String.t()) :: String.t()
  def json(name) when is_binary(name), do: File.read!(Path.join(@dir, name <> ".json"))

  @doc "The raw golden file `name` (`parent-default` or `child-suite`)."
  @spec golden_json(String.t()) :: String.t()
  def golden_json(name) when is_binary(name), do: File.read!(Path.join(@golden, name <> ".json"))

  @doc "The decoded synthetic fixture `name` (without `.json`)."
  @spec document(String.t()) :: map()
  def document(name) when is_binary(name) do
    {:ok, decoded} = JsonDocument.decode(json(name))
    {:ok, normalized} = JsonDocument.normalize(decoded)
    normalized
  end

  @doc "The minimal valid document."
  @spec minimal() :: map()
  def minimal, do: document("minimal")

  @doc "A document with source, partitions, and command costs."
  @spec full() :: map()
  def full, do: document("full")

  @doc """
  Inserts one stored run for `project` and returns its server id.

  `attrs` overrides column values. The row is enough for deletion and
  foreign-key tests; `GoodFlows.WorkflowRuns.ingest/4` is the upload path.
  """
  @spec stored_run(struct(), struct(), map()) :: Ecto.UUID.t()
  def stored_run(account, project, attrs \\ %{}) do
    id = Ecto.UUID.generate()
    payload = %{"schema_version" => 1}

    row =
      Map.merge(
        %{
          id: id,
          account_id: account.id,
          project_id: project.id,
          run_id: Ecto.UUID.generate(),
          workflow: "ci",
          outcome: "passed",
          started_at: ~U[2026-11-05 12:00:00Z],
          duration_ms: 0,
          parallelism: 1,
          max_in_flight: 0,
          graph_sha256: @graph,
          host: %{"os" => "linux", "arch" => "x86_64", "logical_cpus" => 1},
          payload: payload,
          inserted_at: DateTime.utc_now()
        },
        attrs
      )

    Repo.insert_all(Run, [Map.put(row, :payload_digest, JsonDocument.digest(row.payload))])
    id
  end
end
