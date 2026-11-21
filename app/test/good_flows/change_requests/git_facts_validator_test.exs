defmodule GoodFlows.ChangeRequests.GitFactsValidatorTest do
  use ExUnit.Case, async: true

  import GoodFlows.ChangeRequestFixtures

  alias GoodFlows.ChangeRequests.GitFactsValidator

  defp errors(document, target \\ "main") do
    {:error, {:invalid_body, errors}} = GitFactsValidator.validate(document, target)
    errors
  end

  test "a valid document is returned as given" do
    doc = git_facts(sha(1))
    assert {:ok, ^doc} = GitFactsValidator.validate(doc, "main")
  end

  test "format, keys, SHAs and the target branch" do
    assert errors(Map.put(git_facts(sha(1)), "format", "git-facts/2"))["format"]
    assert errors(Map.put(git_facts(sha(1)), "extra", 1))["body"] == ["has an unknown field"]
    assert errors(put_in(git_facts(sha(1)), ["target", "x"], 1))["target"]
    assert errors(put_in(git_facts(sha(1)), ["diff", "x"], 1))["diff"]
    assert errors(Map.put(git_facts(sha(0xABC)), "head", String.upcase(sha(0xABC))))["head"]
    assert errors(git_facts(sha(1), target: "release"))["target.branch"]
    assert errors(put_in(git_facts(sha(1)), ["target", "merge_base"], "abc"))["target.merge_base"]
  end

  test "commits end at head and are empty only at the merge base" do
    doc = git_facts(sha(1))
    assert errors(put_in(doc, ["commits", Access.at(0), "sha"], sha(2)))["commits"]
    assert errors(Map.put(doc, "commits", []))["commits"]

    at_base = doc |> Map.put("commits", []) |> put_in(["target", "merge_base"], sha(1))
    assert {:ok, _} = GitFactsValidator.validate(at_base, "main")

    assert errors(put_in(doc, ["commits", Access.at(0), "parents"], []))["commits[0].parents"]
    assert errors(put_in(doc, ["commits", Access.at(0), "x"], 1))["commits[0]"]
  end

  test "file entries" do
    with_files = fn files -> git_facts(sha(1), files: files) end

    assert errors(with_files.([file("a", status: "renamed")]))["diff.files[0].old_path"]
    assert errors(with_files.([file("a", old_path: "b")]))["diff.files[0].old_path"]

    assert {:ok, _} =
             GitFactsValidator.validate(
               with_files.([file("a", status: "copied", old_path: "b")]),
               "main"
             )

    assert errors(with_files.([file("a", status: "unmerged")]))["diff.files[0].status"]
    assert errors(with_files.([file("/etc/passwd")]))["diff.files[0].path"]
    assert errors(with_files.([file("a\tb")]))["diff.files[0].path"]
    assert errors(with_files.([file(String.duplicate("a", 4097))]))["diff.files[0].path"]
    assert errors(with_files.([file("a", additions: -1)]))["diff.files[0].additions"]
    assert errors(with_files.([file("a", extra: 1)]))["diff.files[0]"]
    assert errors(with_files.([file("lib/a.ex"), file("lib/a.ex")]))["diff.files"]
    assert errors(with_files.([file("lib/a.ex"), file("lib/a.ex")]))["commits[0].changed_files"]
  end

  test "limits, and documents at the limits pass" do
    head = sha(1_000)

    commits =
      for n <- 1..1_000,
          do: %{"sha" => sha(n), "parents" => [sha(n - 1)], "changed_files" => [file("a")]}

    files = for n <- 1..10_000, do: file("f/#{n}")

    at_limits =
      git_facts(head) |> Map.put("commits", commits) |> put_in(["diff", "files"], files)

    assert {:ok, _} = GitFactsValidator.validate(at_limits, "main")

    over =
      Map.put(
        at_limits,
        "commits",
        commits ++ [%{"sha" => sha(1_001), "parents" => [head], "changed_files" => []}]
      )

    assert errors(Map.put(over, "head", sha(1_001)))["commits"]

    assert errors(put_in(at_limits, ["diff", "files"], [file("x") | files]))["diff.files"]

    changed = put_in(at_limits, ["commits", Access.at(0), "changed_files"], [file("x") | files])
    assert errors(changed)["commits[0].changed_files"]
  end
end
