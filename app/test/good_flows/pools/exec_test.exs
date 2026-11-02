defmodule GoodFlows.Pools.ExecTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Pools.Exec

  defp exec(attrs) do
    struct(
      %Exec{
        id: Ecto.UUID.generate(),
        status: "exited",
        exit_code: 0,
        duration_ms: 5,
        outputs: nil,
        outputs_truncated: false,
        collect_reports: true,
        reports: nil,
        reports_truncated: false,
        collect_failed: false,
        final_output_seq: 3
      },
      attrs
    )
  end

  test "a failed collect leaves outputs and reports missing (null), not empty" do
    payload = Exec.exit_payload(exec(%{collect_failed: true}))

    assert payload.collect_failed
    assert payload.outputs == nil
    assert payload.reports == nil
  end

  test "a successful collect with reports requested always carries the manifest" do
    files = [%{"name" => "a.jsonl", "size" => 3, "too_large" => false}]

    payload =
      Exec.exit_payload(
        exec(%{
          outputs: "{}",
          reports: %{"files" => files, "skipped" => 2},
          reports_truncated: true
        })
      )

    assert payload.outputs == Base.encode64("{}")
    assert payload.reports == %{files: files, truncated: true, skipped: 2}
    assert Exec.exit_event(exec(%{})).final_output_seq == 3
  end

  test "without collect_reports, reports is null" do
    assert Exec.exit_payload(exec(%{collect_reports: false})).reports == nil
  end
end
