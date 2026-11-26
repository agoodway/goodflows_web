defmodule GoodFlows.ScenarioSets.SectionsTest do
  use ExUnit.Case, async: true

  alias GoodFlows.ScenarioSets.Sections

  @fixture Path.expand("../../support/fixtures/scenario_sets", __DIR__)
  @content File.read!(Path.join(@fixture, "goodflows_test_cr1_diff_v1.md"))
  @sections @fixture
            |> Path.join("goodflows_test_cr1_diff_v1.sections.json")
            |> File.read!()
            |> Jason.decode!()

  defp sha(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  defp sections_of(ids_and_sections),
    do:
      Enum.map(ids_and_sections, fn {id, section} -> %{"id" => id, "sha256" => sha(section)} end)

  defp slice(text, from, to) do
    start = :binary.match(text, from) |> elem(0)

    finish =
      case to do
        :eof -> byte_size(text)
        to -> :binary.match(text, to) |> elem(0)
      end

    binary_part(text, start, finish - start)
  end

  test "every section of the real diff set matches the digest its CLI sent" do
    split = Sections.split(@content, @sections)

    assert Map.keys(split) == ~w(1 2 3 4 5 6)
    assert Enum.all?(Map.values(split), &match?({:ok, _text}, &1))

    {:ok, two} = split["2"]
    refute two =~ "### 2."
    assert String.starts_with?(two, "Why: an update that wipes the fields")
    assert two =~ "4. Send `GET /todos/1`."
    assert String.ends_with?(two, "{\"id\":1,\"title\":\"buy oat milk\",\"done\":true}`.")

    {:ok, six} = split["6"]
    assert String.ends_with?(six, "body `{\"status\":\"ok\"}`.")
    refute six =~ "Regression checks"
  end

  test "a one-byte edit makes only that section unmatched" do
    edited =
      String.replace(@content, "status `204` and an empty body", "status `204` and an empty bodY")

    split = Sections.split(edited, @sections)

    assert split["3"] == :unmatched
    assert Enum.all?(Map.delete(split, "3"), &match?({_id, {:ok, _text}}, &1))
  end

  test "scenarios under group headings run to the next heading of their level or higher" do
    text = """
    ---
    format: qa-scenarios/2
    ---

    ## What changed

    ### 1. Not a scenario

    ## Scenarios

    ### Free plan

    Sign in as free@example.com.

    #### 1. Add a seat (Must)

    1. Click **Add seat**.
       - Expect: 2 seats.

    #### 2. Last seat (Should)

    steps

    ### Team plan

    #### 3. Remove a seat (Must)

    gone

    ## Regression checks

    - none
    """

    one = slice(text, "#### 1.", "#### 2.")
    two = slice(text, "#### 2.", "### Team")
    three = slice(text, "#### 3.", "## Regression")
    split = Sections.split(text, sections_of([{"1", one}, {"2", two}, {"3", three}]))

    assert split["1"] == {:ok, "1. Click **Add seat**.\n   - Expect: 2 seats."}
    assert split["2"] == {:ok, "steps"}
    assert split["3"] == {:ok, "gone"}
  end

  test "a heading inside a fenced block does not end a section" do
    text = """
    ---
    format: qa-scenarios/2
    ---
    ## Scenarios

    ### 1. One

    ```text
    ### 2. Not a heading
    ```

    ~~~
    ## Not a heading either
    ```
    ~~~

    ### 2. Two

    two
    """

    one = slice(text, "### 1.", "### 2. Two")
    two = slice(text, "### 2. Two", :eof)
    split = Sections.split(text, sections_of([{"1", one}, {"2", two}]))

    assert {:ok, text_one} = split["1"]
    assert text_one =~ "### 2. Not a heading"
    assert text_one =~ "## Not a heading either"
    assert split["2"] == {:ok, "two"}
  end

  test "CRLF line endings are kept in the hashed bytes" do
    text =
      "---\r\nformat: qa-scenarios/2\r\n---\r\n## Scenarios\r\n\r\n### 1. One\r\n\r\nWhy: x\r\n\r\n### 2. Two\r\n\r\ny\r\n"

    one = slice(text, "### 1.", "### 2.")
    two = slice(text, "### 2.", :eof)
    split = Sections.split(text, sections_of([{"1", one}, {"2", two}]))

    assert split["1"] == {:ok, "Why: x"}
    assert split["2"] == {:ok, "y"}

    lf = String.replace(text, "\r\n", "\n")
    assert Sections.split(lf, sections_of([{"1", one}, {"2", two}]))["1"] == :unmatched
  end

  test "a non-ASCII name and text are cut on bytes" do
    text =
      "## Scenarios\n\n### ünïcode-1. Grüße an Zoë 🚀 (Must)\n\nSchritt — eins\n\n### 2. Two\n\nzwei\n"

    one = slice(text, "### ü", "### 2.")
    two = slice(text, "### 2.", :eof)
    split = Sections.split(text, sections_of([{"ünïcode-1", one}, {"2", two}]))

    assert split["ünïcode-1"] == {:ok, "Schritt — eins"}
    assert split["2"] == {:ok, "zwei"}
  end

  test "a missing, duplicated or out-of-range heading is unmatched" do
    text =
      "### 1. Before\n\n## Scenarios\n\n### 2. Two\n\na\n\n### 2. Again\n\nb\n\n### 10. Ten\n"

    sections = [%{"id" => "1", "sha256" => sha("x")}, %{"id" => "2", "sha256" => sha("x")}]

    assert Sections.split(text, sections) == %{"1" => :unmatched, "2" => :unmatched}

    assert Sections.split("no scenarios heading", sections) == %{
             "1" => :unmatched,
             "2" => :unmatched
           }
  end
end
