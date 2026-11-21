defmodule GoodFlows.ChangeRequests.ClaimsDocumentTest do
  use ExUnit.Case, async: true

  import GoodFlows.ChangeRequestFixtures

  alias GoodFlows.ChangeRequests.ClaimsDocument

  @head sha(1)
  @context %{number: 42, head: @head, diff_paths: MapSet.new(["lib/a.ex", "lib/old.ex"])}

  defp parse_errors(raw) do
    {:error, {:invalid_body, errors}} = ClaimsDocument.parse(raw)
    errors
  end

  defp errors(overrides, context \\ @context) do
    {:ok, front_matter} = ClaimsDocument.parse(claims(front_matter(@head, overrides)))
    {:error, {:invalid_body, errors}} = ClaimsDocument.validate(front_matter, context)
    errors
  end

  defp valid?(overrides, context \\ @context) do
    {:ok, front_matter} = ClaimsDocument.parse(claims(front_matter(@head, overrides)))
    ClaimsDocument.validate(front_matter, context) == :ok
  end

  describe "parse/1" do
    test "reads block YAML front matter and never parses the body" do
      raw = """
      ---
      format: change-claims/2
      cr: 42
      head: "#{@head}"
      door: one_way
      safe_because:
        - fact: Keys are scoped
          proof: ran
      ---
      # What changed
      --- not front matter ---
      : not: [yaml
      """

      assert {:ok, %{"cr" => 42, "door" => "one_way", "safe_because" => [%{"proof" => "ran"}]}} =
               ClaimsDocument.parse(raw)
    end

    test "front matter must open and close with --- lines and be a mapping" do
      assert parse_errors("# Title\n")["front_matter"]
      assert parse_errors("---\nformat: change-claims/2\n")["front_matter"]
      assert parse_errors("---\n- 1\n---\n")["front_matter"]
      assert parse_errors("---\na: [\n---\n")["front_matter"]
      assert {:ok, %{"a" => 1}} = ClaimsDocument.parse("---\r\na: 1\r\n---\r\nbody")

      for yaml <- [
            "x: a\u0000b",
            "x: \"a\u0000b\"",
            "x: 'a\u0000b'",
            "x: \x01",
            "x: a\x1bb",
            ~s({"x": "a\u0000b"})
          ] do
        assert parse_errors("---\n" <> yaml <> "\n---\n")["front_matter"] == ["is not valid YAML"],
               inspect(yaml)
      end
    end

    test "a plain integer of more than 32 digits is refused before it is built" do
      digits = 200_000

      for yaml <- [
            "x: " <> String.duplicate("9", digits),
            "x: -0x" <> String.duplicate("f", digits),
            "x: 0o" <> String.duplicate("7", digits),
            String.duplicate("9", digits) <> ": 1",
            ~s({"x": #{String.duplicate("9", digits)}})
          ] do
        {micros, errors} = :timer.tc(fn -> parse_errors("---\n" <> yaml <> "\n---\n") end)

        assert errors["front_matter"] == ["must not have an integer of more than 32 digits"]
        assert micros < 500_000, "took #{div(micros, 1000)} ms"
      end

      assert parse_errors("---\nx: 0x" <> String.duplicate("f", 33) <> "\n---\n")[
               "front_matter"
             ] == ["must not have an integer of more than 32 digits"]

      assert parse_errors("---\nx: " <> String.duplicate("1", 32) <> "\n---\n")["front_matter"] ==
               ["must not contain NUL characters or huge integers"]
    end

    test "plain strings and floats with long digit runs are kept, quickly" do
      long = String.duplicate("9", 200_000)

      for {text, value} <- [
            {long <> "a", long <> "a"},
            {long <> " apples", long <> " apples"},
            {long <> ".9", long <> ".9"},
            {"1_" <> long, "1_" <> long},
            {String.duplicate("9", 300) <> ".5", 1.0e300}
          ] do
        {micros, result} = :timer.tc(fn -> ClaimsDocument.parse("---\nx: #{text}\n---\n") end)

        assert {:ok, %{"x" => ^value}} = result
        assert micros < 1_000_000, "took #{div(micros, 1000)} ms"
      end

      for sha <- [
            "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567",
            "aa1b2c3d4e5f60718293a4b5c6d7e8f901234567",
            "12345678901234567890123456789012345abcde"
          ] do
        assert {:ok, %{"head" => ^sha}} = ClaimsDocument.parse("---\nhead: #{sha}\n---\n")
      end
    end

    test "scalars resolve with the core schema even under a %YAML 1.1 directive" do
      assert {:ok, %{"x" => "yes", "y" => "1_000", "z" => 10}} =
               ClaimsDocument.parse("---\n%YAML 1.1\n--- \nx: yes\ny: 1_000\nz: 010\n---\n")
    end

    test "anchors, aliases, tags and tag directives are rejected" do
      for yaml <- [
            "a: &a 1\nb: *a\n",
            "a: !tag 1\n",
            "a: !!str 1\n",
            "a: !tag {b: 1}\n",
            "a: !<tag:x> 1\n"
          ] do
        assert parse_errors("---\n" <> yaml <> "---\n")["front_matter"] == [
                 "must not use YAML anchors, aliases or tags"
               ],
               yaml
      end
    end

    test "collections may nest 16 levels with the front matter mapping, not 17" do
      nested = &("x: " <> String.duplicate("[", &1) <> String.duplicate("]", &1))
      dashes = &("x:\n  " <> String.duplicate("- ", &1) <> "1")
      indented = &Enum.map_join(0..&1, "\n", fn i -> String.duplicate("  ", i) <> "k:" end)
      json = &(String.duplicate(~s({"k": ), &1) <> "1" <> String.duplicate("}", &1))

      for shape <- [nested, dashes, indented] do
        assert {:ok, _} = ClaimsDocument.parse("---\n" <> shape.(15) <> "\n---\n")

        assert parse_errors("---\n" <> shape.(16) <> "\n---\n")["front_matter"] == [
                 "must not nest collections more than 16 levels deep"
               ]
      end

      assert {:ok, _} = ClaimsDocument.parse("---\n" <> json.(16) <> "\n---\n")

      assert parse_errors("---\n" <> json.(17) <> "\n---\n")["front_matter"] == [
               "must not nest collections more than 16 levels deep"
             ]
    end

    test "deep nesting is refused before yamerl's work can grow" do
      for yaml <- [
            "x: " <> String.duplicate("[", 8_000) <> String.duplicate("]", 8_000),
            "x: " <> String.duplicate("{a: ", 8_000) <> String.duplicate("}", 8_000),
            "x:\n  " <> String.duplicate("- ", 8_000) <> "1",
            "x:\n  " <> String.duplicate("? ", 8_000) <> "1"
          ] do
        {micros, errors} = :timer.tc(fn -> parse_errors("---\n" <> yaml <> "\n---\n") end)

        assert errors["front_matter"] == ["must not nest collections more than 16 levels deep"]
        assert micros < 500_000, "took #{div(micros, 1000)} ms"
      end
    end

    test "a large flow collection that could be a key is refused, a JSON object is not" do
      items = Enum.map_join(1..20_000, ",", fn _ -> "a" end)

      for yaml <- ["x: [[#{items}]]", "x:\n  - [#{items}]", "{x: [#{items}]}"] do
        {micros, errors} = :timer.tc(fn -> parse_errors("---\n" <> yaml <> "\n---\n") end)

        assert errors["front_matter"] == [
                 "must not have a flow collection of more than 256 tokens that could be a key"
               ]

        assert micros < 500_000, "took #{div(micros, 1000)} ms"
      end

      assert {:ok, %{"x" => list}} = ClaimsDocument.parse("---\nx: [#{items}]\n---\n")
      assert length(list) == 20_000

      json = Jason.encode!(%{"x" => [List.duplicate("a", 20_000)]})
      assert {:ok, %{"x" => [list]}} = ClaimsDocument.parse("---\n" <> json <> "\n---\n")
      assert length(list) == 20_000
    end

    test "a key repeated within one mapping is rejected" do
      for yaml <- [
            "door: two_way\ndoor: one_way",
            "a:\n  b: 1\n  b: 2",
            "a: 1\n\"a\": 2",
            "a: [{b: 1, b: 2}]",
            ~s({"door": "two_way", "door": "one_way"}),
            ~s({"a": {"b": 1, "b": 2}})
          ] do
        assert parse_errors("---\n" <> yaml <> "\n---\n")["front_matter"] == [
                 "has a duplicate key"
               ],
               yaml
      end

      assert {:ok, _} = ClaimsDocument.parse("---\na: {b: 1}\nc: {b: 2}\nd: b\n---\n")
      assert {:ok, _} = ClaimsDocument.parse("---\na:\n  - b: 1\n  - b: 2\n---\n")
    end

    test "a second YAML document is rejected" do
      for yaml <- ["door: two_way\n...\n--- \ndoor: one_way", "door: two_way\n--- door: one_way"] do
        assert parse_errors("---\n" <> yaml <> "\n---\n")["front_matter"] == [
                 "must be a single YAML document"
               ],
               yaml
      end

      assert {:ok, %{"door" => "two_way"}} =
               ClaimsDocument.parse("---\ndoor: two_way\n...\n---\n")
    end
  end

  describe "validate/2" do
    test "the default front matter is valid, cr may be null or the number" do
      assert valid?(%{})
      assert valid?(%{"cr" => 42})
      assert errors(%{"cr" => 41})["cr"]
      assert errors(%{"cr" => "42"})["cr"]
    end

    test "keys and format" do
      assert errors(%{"reviewers" => []})["front_matter"] == ["has an unknown field"]

      assert errors(%{"format" => "change-claims/1"}) == %{
               "format" => ["must be change-claims/2"]
             }

      {:ok, missing} = ClaimsDocument.parse(claims(Map.delete(front_matter(@head), "reach")))

      assert {:error, {:invalid_body, %{"reach" => ["is required"]}}} =
               ClaimsDocument.validate(missing, @context)
    end

    test "field shapes and counts" do
      assert errors(%{"door" => "revolving"})["door"]
      assert errors(%{"door_reason" => ""})["door_reason"]
      assert errors(%{"reach" => "  "})["reach"]
      assert errors(%{"safe_because" => []})["safe_because"]

      decision = &%{"id" => "d#{&1}", "path" => "lib/a.ex", "hunk" => "@@", "note" => "n"}
      assert errors(%{"decisions" => Enum.map(1..4, decision)})["decisions"]
      assert valid?(%{"decisions" => Enum.map(1..3, decision)})

      question = %{
        "id" => "q1",
        "text" => "Which?",
        "options" => ["a", "b"],
        "recommendation" => "c"
      }

      assert errors(%{"questions" => [question]})["questions[0].recommendation"]
      assert valid?(%{"questions" => [%{question | "recommendation" => "a"}]})

      assert errors(%{
               "questions" => [
                 %{question | "recommendation" => "a"},
                 %{question | "recommendation" => "a"}
               ]
             })["questions[1].id"]

      risk = %{"risk" => "r", "location" => "l", "affected" => "a"}
      assert valid?(%{"left_open" => [risk]})
      assert errors(%{"left_open" => [Map.put(risk, "x", 1)]})["left_open[0]"]
      assert errors(%{"left_open" => List.duplicate(risk, 101)})["left_open"]
    end

    test "safe_because entries" do
      entry = hd(front_matter(@head)["safe_because"])

      assert errors(%{"safe_because" => [Map.put(entry, "x", 1)]})["safe_because[0]"]

      assert errors(%{"safe_because" => [%{entry | "proof" => "tested"}]})[
               "safe_because[0].proof"
             ]

      incomplete =
        Map.put(entry, "covers", %{
          "capability" => "exports",
          "requirement" => "Export is audited"
        })

      assert errors(%{"safe_because" => [incomplete]})["safe_because[0].covers"]

      covers = %{
        "capability" => "exports",
        "requirement" => "Export is audited",
        "scenario" => "S"
      }

      assert valid?(%{"safe_because" => [Map.put(entry, "covers", covers)]})

      assert errors(%{"safe_because" => [%{entry | "evidence" => ["/etc/passwd"]}]})[
               "safe_because[0].evidence"
             ]

      assert errors(%{"safe_because" => [%{entry | "evidence" => List.duplicate("a", 21)}]})[
               "safe_because[0].evidence"
             ]

      assert errors(%{"safe_because" => [%{entry | "evidence" => []}]})[
               "safe_because[0].evidence"
             ]

      assert errors(%{"safe_because" => [Map.delete(entry, "evidence")]})[
               "safe_because[0].evidence"
             ]

      assert valid?(%{
               "safe_because" => [entry |> Map.delete("evidence") |> Map.put("proof", "walked")]
             })

      ran = %{
        entry
        | "evidence" => [
            ".verify/web/r1/run.md#S1",
            "app/test/good_flows/caches_test.exs:42",
            ".verify/web/missing/run.md"
          ]
      }

      assert valid?(%{"safe_because" => [ran]})
    end

    test "server checks against the head and its diff" do
      assert errors(%{"head" => sha(2)})["head"]
      assert errors(%{}, %{@context | head: nil, diff_paths: nil})["head"]

      decision = %{"id" => "d1", "path" => "lib/other.ex", "hunk" => "@@", "note" => "n"}
      assert errors(%{"decisions" => [decision]})["decisions[0].path"]
      assert valid?(%{"decisions" => [%{decision | "path" => "lib/old.ex"}]})

      entry = hd(front_matter(@head)["safe_because"])
      assert valid?(%{"safe_because" => [%{entry | "location" => "lib/missing.ex:999"}]})
    end
  end
end
