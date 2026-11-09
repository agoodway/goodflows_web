defmodule GoodFlows.TestReports.ShapeTest do
  use ExUnit.Case, async: true

  alias GoodFlows.TestReports.Shape

  @shape {:object, %{"id" => {:int, 1}, "meta" => {:optional, {:object, %{"x" => :boolean}}}}}

  test "an absent optional key is accepted" do
    assert Shape.check(%{"id" => 1}, @shape, []) == []
  end

  test "a present optional key is checked on its own path, including null" do
    assert Shape.check(%{"id" => 1, "meta" => %{"x" => true}}, @shape, []) == []

    assert Shape.check(%{"id" => 1, "meta" => %{"x" => 1}}, @shape, []) ==
             [{["meta", "x"], "must be a boolean"}]

    assert Shape.check(%{"id" => 1, "meta" => nil}, @shape, []) ==
             [{["meta"], "must be an object"}]
  end

  test "a required key is still required next to an optional one" do
    assert Shape.check(%{"meta" => %{"x" => true}}, @shape, []) == [{["id"], "is required"}]
    assert Shape.check(%{"id" => 1, "other" => 1}, @shape, []) == [{[], "has an unknown field"}]
  end

  describe "omit-only keys" do
    @omit {:object, %{"id" => {:int, 1}, "note" => {:omit, {:string, min: 1}}}}

    test "an absent omit-only key is accepted and null is invalid" do
      assert Shape.check(%{"id" => 1}, @omit, []) == []

      assert Shape.check(%{"id" => 1, "note" => nil}, @omit, []) ==
               [{["note"], "is invalid"}]
    end

    test "a present omit-only key is checked against its spec" do
      assert Shape.check(%{"id" => 1, "note" => "ci"}, @omit, []) == []
      assert Shape.check(%{"id" => 1, "note" => ""}, @omit, []) == [{["note"], "can't be blank"}]
    end
  end

  describe "list bounds" do
    @jobs {:list, {:string, min: 1}, min: 1, max: 2}

    test "a list below its minimum is empty and entries are not checked" do
      assert Shape.check([], @jobs, []) == [{[], "must not be empty"}]
    end

    test "a list above its maximum reports only the cap" do
      assert Shape.check(["", "", ""], @jobs, []) == [{[], "must not have more than 2 entries"}]
    end

    test "a list within bounds checks every entry" do
      assert Shape.check(["a", ""], @jobs, []) == [{[1], "can't be blank"}]
    end
  end

  describe "non-blank strings" do
    @name {:string, min: 1, max: 64, no_control: true, non_blank: true}

    test "whitespace-only text is blank when the name rule asks for it" do
      assert Shape.check("   ", @name, []) == [{[], "can't be blank"}]
      assert Shape.check("ci", @name, []) == []
    end

    test "without the name rule a whitespace string of the minimum length still passes" do
      assert Shape.check("   ", {:string, min: 1, no_control: true}, []) == []
    end
  end
end
