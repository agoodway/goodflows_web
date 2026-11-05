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
end
