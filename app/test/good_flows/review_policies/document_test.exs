defmodule GoodFlows.ReviewPolicies.DocumentTest do
  use ExUnit.Case, async: true

  alias GoodFlows.DocumentErrors
  alias GoodFlows.ReviewPolicies.{Document, Glob}

  defp write(policy, extra \\ %{}),
    do: Map.merge(%{"previous_version" => 0, "policy" => policy}, extra)

  defp errors(body) do
    {:error, errors} = Document.validate_write(body)
    DocumentErrors.render(errors)
  end

  defp policy(sections), do: Map.merge(%{"format" => "review-policy/1"}, sections)

  describe "version 0" do
    test "the effective document of a bare format equals the default" do
      assert Document.effective(%{"format" => "review-policy/1"}) == Document.default()
    end

    test "the default turns off required workflows and the phase 2 checks" do
      default = Document.default()
      assert default["evidence"]["required_workflows"] == []
      assert default["scenarios"]["require_approved_intent"] == false
      assert default["scenarios"]["spec_gaps"] == "ignore"
      assert default["coverage"]["unmapped_areas"] == "ignore"
      assert default["coverage"]["undriven_features"] == "ignore"
      assert default["claims"]["min_proof_level"] == "ran"
      assert default["size"]["max_changed_files"] == 40
    end

    test "omitted keys keep their default, paths are replaced whole" do
      effective =
        Document.effective(policy(%{"size" => %{"max_changed_files" => 10}, "paths" => []}))

      assert effective["size"] == %{"max_changed_files" => 10, "max_changed_lines" => 1500}
      assert effective["paths"] == []
    end
  end

  test "active settings cover phase 1 only" do
    active = Document.active_settings()
    assert "claims.one_way_door" in active
    assert "evidence.required_workflows" in active
    assert "paths" in active
    assert "size.max_changed_lines" in active

    refute Enum.any?(active, &String.starts_with?(&1, ["scenarios.", "coverage.", "merge."]))
    refute "evidence.ignore_paths" in active
  end

  describe "validate_write/1" do
    test "accepts the full D5 example and keeps it as given" do
      full =
        policy(%{
          "scenarios" => %{
            "require_approved_intent" => true,
            "should_failures" => "needs_review",
            "spec_gaps" => "ignore",
            "approver" => "any"
          },
          "evidence" => %{"required_workflows" => ["ci"], "ignore_paths" => ["docs/**"]},
          "claims" => %{
            "one_way_door" => "needs_review",
            "min_proof_level" => "ran",
            "open_items" => "needs_review"
          },
          "paths" => [%{"glob" => "app/priv/repo/migrations/**", "outcome" => "needs_review"}],
          "size" => %{"max_changed_files" => 40, "max_changed_lines" => 1500},
          "coverage" => %{"unmapped_areas" => "needs_review", "undriven_features" => "blocked"},
          "merge" => %{"lease_ttl" => "10m", "regrade_merge_result" => true}
        })

      assert {:ok, %{policy: ^full, previous_version: 0, note: "n"}} =
               Document.validate_write(write(full, %{"note" => "n"}))
    end

    test "unknown sections, keys and body keys" do
      assert errors(write(policy(%{"rules" => []})))["policy"] == ["has an unknown field"]

      assert errors(write(policy(%{"claims" => %{"max_open_items" => 3}})))["policy.claims"] ==
               ["has an unknown field"]

      paths = [%{"glob" => "app/priv/**", "outcome" => "blocked", "note" => "db"}]
      assert errors(write(policy(%{"paths" => paths})))["policy.paths[0]"]
      assert errors(Map.put(write(policy(%{})), "x", 1))["body"] == ["has an unknown field"]
    end

    test "format, nulls and outcome enums" do
      assert errors(write(%{"format" => "review-policy/2"}))["policy.format"]
      assert errors(write(%{}))["policy.format"] == ["is required"]
      assert errors(write(policy(%{"size" => nil})))["policy.size"] == ["is invalid"]

      assert errors(write(policy(%{"claims" => %{"one_way_door" => nil}})))[
               "policy.claims.one_way_door"
             ]

      assert errors(write(policy(%{"claims" => %{"one_way_door" => "pending"}})))[
               "policy.claims.one_way_door"
             ]

      assert errors(write(policy(%{"claims" => %{"min_proof_level" => "tested"}})))[
               "policy.claims.min_proof_level"
             ]

      assert errors(write(policy(%{"scenarios" => %{"spec_gaps" => "blocked"}})))[
               "policy.scenarios.spec_gaps"
             ]

      assert errors(write(policy(%{"scenarios" => %{"approver" => "owner"}})))[
               "policy.scenarios.approver"
             ]
    end

    test "required workflows, sizes, booleans and paths" do
      assert errors(write(policy(%{"evidence" => %{"required_workflows" => ["ci", "ci"]}})))[
               "policy.evidence.required_workflows"
             ]

      too_many = Enum.map(1..33, &"w#{&1}")

      assert errors(write(policy(%{"evidence" => %{"required_workflows" => too_many}})))[
               "policy.evidence.required_workflows"
             ]

      assert errors(write(policy(%{"evidence" => %{"required_workflows" => [""]}})))[
               "policy.evidence.required_workflows"
             ]

      assert errors(write(policy(%{"size" => %{"max_changed_files" => 0}})))[
               "policy.size.max_changed_files"
             ]

      assert errors(write(policy(%{"size" => %{"max_changed_lines" => 1.5}})))[
               "policy.size.max_changed_lines"
             ]

      assert errors(write(policy(%{"scenarios" => %{"require_approved_intent" => "yes"}})))[
               "policy.scenarios.require_approved_intent"
             ]

      assert errors(write(policy(%{"merge" => %{"regrade_merge_result" => 1}})))[
               "policy.merge.regrade_merge_result"
             ]

      dup = [
        %{"glob" => "app/priv/**", "outcome" => "blocked"},
        %{"glob" => "app/priv/**", "outcome" => "ignore"}
      ]

      assert errors(write(policy(%{"paths" => dup})))["policy.paths"]

      brace = [%{"glob" => "lib/{a,b}.ex", "outcome" => "blocked"}]
      assert errors(write(policy(%{"paths" => brace})))["policy.paths[0].glob"]

      star = [%{"glob" => "lib/**.ex", "outcome" => "blocked"}]
      assert errors(write(policy(%{"paths" => star})))["policy.paths[0].glob"]

      assert errors(write(policy(%{"evidence" => %{"ignore_paths" => ["/etc/**"]}})))[
               "policy.evidence.ignore_paths[0]"
             ]
    end

    test "lease_ttl is a duration from 1m to 1h" do
      for ok <- ~w(90s 1m 60s 10m 1h 3600s) do
        assert {:ok, _} =
                 Document.validate_write(write(policy(%{"merge" => %{"lease_ttl" => ok}}))),
               ok
      end

      for bad <- ~w(30s 59s 2h 61m 2d 0m 10 m10) ++ [""] do
        assert errors(write(policy(%{"merge" => %{"lease_ttl" => bad}})))[
                 "policy.merge.lease_ttl"
               ],
               bad
      end
    end

    test "note is 1 to 1024 bytes and previous_version nonnegative" do
      assert errors(write(policy(%{}), %{"note" => ""}))["note"]
      assert errors(write(policy(%{}), %{"note" => String.duplicate("a", 1025)}))["note"]

      assert {:ok, _} =
               Document.validate_write(
                 write(policy(%{}), %{"note" => String.duplicate("a", 1024)})
               )

      assert errors(%{"previous_version" => -1, "policy" => policy(%{})})["previous_version"]
    end
  end

  describe "globs" do
    defp matches?(glob, path), do: Glob.match?(Glob.compile(glob), path)

    test "double star crosses segments, single star and ? stay in one" do
      assert matches?("app/priv/repo/migrations/**", "app/priv/repo/migrations/2026/a.exs")
      assert matches?("app/priv/repo/migrations/**", "app/priv/repo/migrations/a.exs")
      refute matches?("lib/*.ex", "lib/good_flows/a.ex")
      assert matches?("lib/*.ex", "lib/a.ex")
      assert matches?("lib/?.ex", "lib/a.ex")
      refute matches?("lib/?.ex", "lib/ab.ex")
      refute matches?("lib?a.ex", "lib/a.ex")
    end

    test "leading, middle and lone double stars" do
      assert matches?("**/*.md", "README.md")
      assert matches?("**/*.md", "docs/a/b.md")
      assert matches?("app/**/test.exs", "app/test.exs")
      assert matches?("app/**/test.exs", "app/x/y/test.exs")
      assert matches?("**", "any/path")
      assert matches?("a/**/**/b", "a/x/b")
    end

    test "whole path only, regex characters are literal" do
      refute matches?("lib", "lib/a.ex")
      refute matches?("a.ex", "xa.ex")
      refute matches?("a.ex", "abex")
      assert matches?("a+(b).ex", "a+(b).ex")
    end

    test "invalid globs" do
      for bad <- ["", "/abs", "lib/[ab].ex", "lib/{a}.ex", "a\\b", "lib/**.ex", "x**/a", "a\nb"] do
        assert Glob.error(bad), inspect(bad)
      end

      assert Glob.error(String.duplicate("a", 1025))
      assert Glob.error(1)
      assert Glob.error("lib/**/a.ex") == nil
    end
  end
end
