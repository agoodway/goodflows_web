defmodule GoodFlows.Spry.TemplateTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Spry.Template

  @remote "git@github.com:example-org/example-app.git"

  defp values(branch, extra \\ %{}) do
    Map.merge(
      %{
        "branch" => branch,
        "branch_slug" => branch && Template.slug(branch),
        "commit" => "abc123def",
        "remote" => @remote
      },
      extra
    )
  end

  describe "slug/1" do
    test "hyphenates a slashed branch" do
      assert Template.slug("feature/add-dashboard") == "feature-add-dashboard"
    end

    test "collapses adjacent separators" do
      assert Template.slug("feat//x y") == "feat-x-y"
    end

    test "strips leading and trailing separators and keeps case" do
      assert Template.slug("/Feat_1.2/") == "Feat_1.2"
      assert Template.slug("///") == ""
    end
  end

  describe "scan/2" do
    test "lists known placeholders" do
      assert Template.scan("app-{{branch_slug}}-{{commit}}", :name) ==
               {:ok, ["branch_slug", "commit"]}

      assert Template.scan("echo {{sprite}} {{remote}}", :step) == {:ok, ["sprite", "remote"]}
    end

    test "interior whitespace is unknown" do
      assert Template.scan("git checkout {{ branch }}", :step) ==
               {:error, {:unknown, [" branch "]}}
    end

    test "org is unknown" do
      assert Template.scan("{{org}}", :step) == {:error, {:unknown, ["org"]}}
    end

    test "placeholders are case-sensitive" do
      assert Template.scan("{{Branch}}", :name) == {:error, {:unknown, ["Branch"]}}
    end

    test "sprite is allowed only in step lines" do
      assert Template.scan("app-{{sprite}}", :name) == {:error, {:unknown, ["sprite"]}}
      assert Template.scan("app-{{sprite}}", :step) == {:ok, ["sprite"]}
    end

    test "strings without placeholders scan clean" do
      assert Template.scan("echo hi", :step) == {:ok, []}
    end
  end

  describe "expand/2" do
    test "expands all inputs" do
      assert Template.expand(
               "{{branch}} {{branch_slug}} {{commit}} {{remote}}",
               values("feature/add-dashboard")
             ) == {:ok, "feature/add-dashboard feature-add-dashboard abc123def #{@remote}"}
    end

    test "expands sprite in a step" do
      assert Template.expand("ssh {{sprite}}", values("x", %{"sprite" => "myapp-feat-x"})) ==
               {:ok, "ssh myapp-feat-x"}
    end

    test "values are not re-expanded" do
      assert Template.expand("{{branch}}", values("{{remote}}")) == {:ok, "{{remote}}"}
    end

    test "values are not quoted" do
      assert Template.expand("git checkout {{branch}}", values("feat x")) ==
               {:ok, "git checkout feat x"}
    end

    test "a missing value names the placeholder" do
      assert Template.expand("app-{{branch_slug}}", values(nil)) ==
               {:error, {:missing, "branch_slug"}}

      assert Template.expand("{{remote}}", %{}) == {:error, {:missing, "remote"}}
    end

    test "an empty slug is missing" do
      assert Template.expand("app-{{branch_slug}}", values("///")) ==
               {:error, {:missing, "branch_slug"}}
    end

    test "no placeholders needs no values" do
      assert Template.expand("echo hi", %{}) == {:ok, "echo hi"}
    end
  end

  describe "sprite names" do
    test "gfp- names and templates follow the ordinary sprite name rule" do
      assert Template.valid_name_template?("gfp-{{branch_slug}}")
      assert Template.valid_sprite_name?("gfp-app")
      assert Template.expand("{{branch_slug}}-app", values("gfp")) == {:ok, "gfp-app"}
      refute Template.valid_sprite_name?("GFP-app")
    end
  end
end
