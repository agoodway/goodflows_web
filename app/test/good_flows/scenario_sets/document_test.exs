defmodule GoodFlows.ScenarioSets.DocumentTest do
  use ExUnit.Case, async: true

  import GoodFlows.GradingFixtures

  alias GoodFlows.ScenarioSets.Document

  defp errors(body) do
    assert {:error, {:invalid_body, errors}} = Document.validate(body)
    errors
  end

  defp intent(scenarios \\ [scenario("S1"), scenario("S2", "should")], extra \\ %{}),
    do: intent_fm("add-export", scenarios, extra)

  test "a valid intent set is accepted with string IDs" do
    fm = intent([scenario(1), scenario("S2", "should")])
    assert {:ok, upload} = Document.validate(set_body(fm))
    assert upload.source == "intent"
    assert Enum.map(upload.front_matter["scenarios"], & &1["id"]) == ["1", "S2"]
    assert Enum.map(upload.sections, & &1["id"]) == ["1", "S2"]
  end

  test "a real YAML file with integer ids" do
    content = """
    ---
    format: qa-scenarios/2
    source: intent
    review: null
    change: add-export
    specs: abc1234
    scenarios:
      - id: 1
        name: Export a report
        priority: must
    coverage:
      - capability: exports
        requirement: Export is audited
        scenario: Audit entry written
        status: covered
        scenarios: [1]
    ---
    # Body names S9 which is ignored
    """

    body = %{"content" => content, "sections" => [%{"id" => "1", "sha256" => section_sha("1")}]}
    assert {:ok, upload} = Document.validate(body)
    assert [%{"id" => "1"}] = upload.front_matter["scenarios"]
    assert [%{"scenarios" => ["1"]}] = upload.front_matter["coverage"]
  end

  test "body keys: unknown is 422 on body" do
    body = Map.put(set_body(intent()), "digest", "x")
    assert errors(body) == %{"body" => ["has an unknown field"]}
  end

  test "no front matter and non-mapping front matter are 422 on content" do
    assert %{"content" => _} = errors(%{"content" => "# QA scenarios\n", "sections" => []})
    assert %{"content" => _} = errors(%{"content" => "---\n- a\n---\n", "sections" => []})
  end

  test "unsupported format is 422 on content.format" do
    assert %{"content.format" => _} =
             errors(set_body(intent([scenario("S1")], %{"format" => "qa-scenarios/1"})))
  end

  test "review is stored as given" do
    fm =
      diff_fm("abc1234", [scenario("D1")], %{"review" => "https://github.com/acme/web/pull/12"})

    assert {:ok, %{front_matter: %{"review" => "https://github.com/acme/web/pull/12"}}} =
             Document.validate(set_body(fm))
  end

  test "a diff key on an intent set is an unknown field on content" do
    assert errors(set_body(intent([scenario("S1")], %{"revision" => "abc1234"}))) ==
             %{"content" => ["has an unknown field"]}
  end

  test "scenario entry rules" do
    for scenarios <- [
          [scenario("S1"), scenario("S1")],
          [scenario(1), scenario("1")],
          [scenario(0)],
          [scenario("S1", "blocker")],
          [Map.put(scenario("S1"), "name", String.duplicate("a", 201))],
          [Map.put(scenario("S1"), "extra", 1)],
          [scenario("bad id!")]
        ] do
      fm = intent(scenarios)
      body = %{"content" => set_content(fm), "sections" => []}
      assert %{"content.scenarios" => _} = errors(body), inspect(scenarios)
    end
  end

  test "covers: implied stored, both scenario and implied refused, diff covers refused" do
    covers = [
      %{"capability" => "exports", "requirement" => "Export is audited", "implied" => true}
    ]

    fm = intent([scenario("S1", "must", %{"covers" => covers})])

    assert {:ok, %{front_matter: %{"scenarios" => [%{"covers" => ^covers}]}}} =
             Document.validate(set_body(fm))

    both = [Map.put(hd(covers), "scenario", "x")]

    assert %{"content.scenarios" => _} =
             errors(set_body(intent([scenario("S1", "must", %{"covers" => both})])))

    diff = diff_fm("abc1234", [scenario("D1", "must", %{"covers" => covers})])
    assert %{"content.scenarios" => _} = errors(set_body(diff))
  end

  test "specs: uncommitted or short hex, required" do
    assert {:ok, _} =
             Document.validate(set_body(intent([scenario("S1")], %{"specs" => "uncommitted"})))

    assert %{"content.specs" => _} =
             errors(set_body(Map.delete(intent([scenario("S1")]), "specs")))

    assert %{"content.specs" => _} =
             errors(set_body(intent([scenario("S1")], %{"specs" => "ABC1234"})))
  end

  test "diff sets: branch, base, revision, regressions" do
    fm =
      diff_fm("abc1234", [scenario("D1")], %{"regressions" => ["Old CSV export still downloads"]})

    assert {:ok, %{front_matter: %{"revision" => "abc1234", "regressions" => [_]}}} =
             Document.validate(set_body(fm))

    assert %{"content.base" => _} = errors(set_body(Map.delete(diff_fm("abc1234"), "base")))
    assert %{"content.revision" => _} = errors(set_body(diff_fm("abc12")))
  end

  test "run results are refused on content" do
    for fm <- [
          intent([scenario("S1", "must", %{"result" => "passed"})]),
          intent([scenario("S1", "must", %{"failed_step" => "x"})]),
          intent([scenario("S1", "must", %{"evidence" => []})]),
          intent([scenario("S1", "must", %{"reason" => "x"})]),
          intent([scenario("S1")], %{"run" => %{"id" => "x"}})
        ] do
      assert %{"content" => [message]} = errors(set_body(fm))
      assert message =~ "verify run"
    end
  end

  describe "coverage rows" do
    defp row(attrs),
      do:
        Map.merge(
          %{
            "capability" => "exports",
            "requirement" => "Export is audited",
            "scenario" => "Audit entry written",
            "status" => "covered",
            "scenarios" => ["S1"]
          },
          attrs
        )

    test "spec gap row, removed-requirement row and integer IDs are stored" do
      rows = [
        row(%{"status" => "no_check", "scenarios" => [], "reason" => "Needs a log reader"}),
        row(%{"scenario" => "[Export is audited] removed", "scenarios" => [1]})
      ]

      fm = intent([scenario(1), scenario("S1")], %{"coverage" => rows})

      assert {:ok, %{front_matter: %{"coverage" => [_gap, %{"scenarios" => ["1"]}]}}} =
               Document.validate(set_body(fm))
    end

    test "row without capability, unknown scenario, duplicates, empty covered" do
      for rows <- [
            [Map.delete(row(%{}), "capability")],
            [row(%{"scenarios" => ["S7"]})],
            [row(%{}), row(%{})],
            [row(%{"scenarios" => []})]
          ] do
        assert %{"content.coverage" => _} =
                 errors(set_body(intent([scenario("S1")], %{"coverage" => rows})))
      end
    end
  end

  describe "sections" do
    test "missing, extra, duplicate and uppercase entries" do
      fm = intent([scenario("S1"), scenario("S2"), scenario("S3")])
      body = set_body(fm)
      [s1, s2, s3] = body["sections"]

      for sections <- [
            [s1, s2],
            [s1, s2, s3, %{"id" => "S4", "sha256" => section_sha("S4")}],
            [s1, s2, s3, s3],
            [s1, s2, %{s3 | "sha256" => String.upcase(s3["sha256"])}]
          ] do
        assert %{"sections" => _} = errors(%{body | "sections" => sections})
      end
    end

    test "IDs match in string form" do
      fm = intent([scenario(1)])

      body = %{
        "content" => set_content(fm),
        "sections" => [%{"id" => "1", "sha256" => section_sha("1")}]
      }

      assert {:ok, _} = Document.validate(body)
    end
  end

  test "errors never echo submitted values" do
    fm = intent([scenario("S1", "SECRETPRIORITY")])
    refute inspect(errors(set_body(fm))) =~ "SECRETPRIORITY"
  end
end
