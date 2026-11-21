defmodule GoodFlows.FrontMatterTest do
  use ExUnit.Case, async: true

  alias GoodFlows.FrontMatter

  test "reads a YAML mapping and never the body" do
    raw = "---\nformat: qa-scenarios/2\nscenarios:\n  - id: 1\n---\n# Body\n\n- id: S9\n: {[\n"

    assert {:ok, %{"format" => "qa-scenarios/2", "scenarios" => [%{"id" => 1}]}} =
             FrontMatter.parse(raw)
  end

  test "CRLF line endings" do
    assert {:ok, %{"a" => 1, "b" => "x"}} =
             FrontMatter.parse("---\r\na: 1\r\nb: x\r\n---\r\nbody")
  end

  test "no front matter" do
    assert {:error, "must start with a --- line"} = FrontMatter.parse("# QA scenarios\n")
    assert {:error, "must end with a --- line"} = FrontMatter.parse("---\na: 1\n")
  end

  test "a non-mapping is refused" do
    assert {:error, "must be a YAML mapping"} = FrontMatter.parse("---\n- 1\n- 2\n---\n")
    assert {:error, "must be a YAML mapping"} = FrontMatter.parse("---\njust text\n---\n")
  end

  test "anchors and duplicate keys are refused" do
    assert {:error, "must not use YAML anchors, aliases or tags"} =
             FrontMatter.parse("---\na: &x 1\nb: *x\n---\n")

    assert {:error, "has a duplicate key"} = FrontMatter.parse("---\na: 1\na: 2\n---\n")
  end
end
