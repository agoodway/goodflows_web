defmodule GoodFlows.VerifyRuns.DocumentTest do
  use ExUnit.Case, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures

  alias GoodFlows.VerifyRuns.Document

  @digest String.duplicate("d", 64)

  defp doc(opts \\ []),
    do: run_doc(@digest, "intent", sha(1), [result("S1"), result(2, "failed")], opts)

  defp errors(body) do
    assert {:error, {:invalid_body, errors}} = Document.validate(body)
    errors
  end

  test "a minimal run is valid and its columns are copied out" do
    assert {:ok, _doc, columns} = Document.validate(doc())
    assert columns.source_commit == sha(1)
    assert columns.dirty == false
    assert columns.scenario_set_digest == @digest
    assert columns.merge_result == false
    assert DateTime.compare(columns.finished_at, columns.started_at) == :gt
  end

  test "format and unknown keys" do
    assert errors(%{doc() | "format" => "verify-run/2"}) == %{
             "format" => ["must be verify-run/1"]
           }

    assert %{"body" => ["has an unknown field"]} = errors(Map.put(doc(), "change_request", 42))
    assert %{"body" => ["has an unknown field"]} = errors(Map.put(doc(), "project", "x"))
  end

  test "run_id, times, source" do
    assert %{"run_id" => _} = errors(%{doc() | "run_id" => String.upcase(Ecto.UUID.generate())})

    assert %{"finished_at" => _} =
             errors(doc(started_at: "2026-11-20T10:00:01Z", finished_at: "2026-11-20T10:00:00Z"))

    assert {:ok, _, _} =
             Document.validate(
               doc(started_at: "2026-11-20T10:00:00+02:00", finished_at: "2026-11-20T08:00:00.5Z")
             )

    assert %{"started_at" => _} = errors(doc(started_at: "yesterday"))
    assert %{"source.commit" => _} = errors(put_in(doc(), ["source", "commit"], "abc1234"))
    assert %{"source.dirty" => _} = errors(update_in(doc(), ["source"], &Map.delete(&1, "dirty")))
    assert {:ok, _, _} = Document.validate(put_in(doc(), ["source", "branch"], nil))
  end

  test "scenario_set shape" do
    assert %{"scenario_set.digest" => _} = errors(put_in(doc(), ["scenario_set", "digest"], "x"))

    assert %{"scenario_set.source" => _} =
             errors(put_in(doc(), ["scenario_set", "source"], "other"))
  end

  test "results: shape, duplicates after string conversion, evidence" do
    assert %{"results" => _} = errors(%{doc() | "results" => [result("S1", "skipped")]})
    assert %{"results" => _} = errors(%{doc() | "results" => [result(2), result("2")]})

    assert %{"results" => _} =
             errors(%{doc() | "results" => [result("S1", "passed", ["shot-4"])]})

    with_artifact =
      doc(artifacts: [artifact("shot-4", "png")])
      |> Map.put("results", [result("S1", "passed", ["shot-4"])])

    assert {:ok, _, _} = Document.validate(with_artifact)
  end

  test "features, drift, links, merge_result, workflow_run_id" do
    assert {:ok, _, _} =
             Document.validate(
               doc(features: [%{"id" => "billing", "entry_point" => "/b", "result" => "passed"}])
             )

    assert %{"features" => _} =
             errors(doc(features: [%{"id" => "x", "entry_point" => nil, "result" => "skipped"}]))

    assert %{"drift" => _} = errors(%{doc() | "drift" => List.duplicate("x", 101)})
    assert {:ok, _, _} = Document.validate(doc(links: %{"tickets" => ["GF-1"]}))
    assert %{"links" => _} = errors(doc(links: %{}))

    assert {:ok, _, %{merge_result: true}} =
             Document.validate(doc(merge_result: %{"base" => sha(3), "commit" => sha(4)}))

    assert {:ok, _, %{merge_result: false}} = Document.validate(doc(merge_result: nil))

    assert %{"merge_result.base" => _} =
             errors(doc(merge_result: %{"base" => "x", "commit" => sha(4)}))

    assert {:ok, _, _} = Document.validate(doc(workflow_run_id: Ecto.UUID.generate()))
    assert %{"workflow_run_id" => _} = errors(doc(workflow_run_id: "nope"))
  end

  test "artifacts: 50 MB is 413, 201 entries and bad entries are 422" do
    big = %{artifact("a", "x") | "size" => 52_428_801}
    assert {:error, :artifact_too_large} = Document.validate(doc(artifacts: [big]))
    assert {:ok, _, _} = Document.validate(doc(artifacts: [%{big | "size" => 52_428_800}]))

    many = for i <- 1..201, do: artifact("a#{i}", "x")
    assert %{"artifacts" => _} = errors(doc(artifacts: many))
    assert %{"artifacts" => _} = errors(doc(artifacts: [artifact("a", "x"), artifact("a", "y")]))
    assert %{"artifacts" => _} = errors(doc(artifacts: [artifact("a", "x", "not a mime")]))
  end

  test "errors never echo values" do
    refute inspect(errors(put_in(doc(), ["source", "commit"], "SECRETVALUE"))) =~ "SECRETVALUE"
  end
end
