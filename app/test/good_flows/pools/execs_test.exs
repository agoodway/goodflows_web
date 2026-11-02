defmodule GoodFlows.Pools.ExecsTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Pools.{Config, Execs}

  @member Ecto.UUID.generate()

  defp validate(attrs), do: Execs.validate_request(Map.merge(%{"member_id" => @member}, attrs))

  defp fields(attrs) do
    assert {:error, %{reason: "invalid_request", fields: fields}} = validate(attrs)
    fields
  end

  describe "validate_request/1" do
    test "a minimal command gets the defaults" do
      assert {:ok, request} = validate(%{"command" => "make"})

      assert request == %{
               member_id: @member,
               argv: ["sh", "-c", "make"],
               cwd: "/workspace",
               env: [],
               timeout_ms: Config.exec_max_ms(),
               collect_reports: false,
               job: nil,
               step: nil
             }
    end

    test "a non-map payload names no fields" do
      assert {:error, %{reason: "invalid_request", fields: []}} = Execs.validate_request("x")
    end

    test "member_id must be a UUID" do
      assert fields(%{"member_id" => "nope", "command" => "x"}) == ["member_id"]

      assert Execs.validate_request(%{"command" => "x"}) |> elem(1) |> Map.get(:fields) == [
               "member_id"
             ]
    end

    test "timeout_ms defaults to and is capped at exec_max_ms" do
      max = Config.exec_max_ms()
      assert {:ok, %{timeout_ms: 10}} = validate(%{"command" => "x", "timeout_ms" => 10})
      assert {:ok, %{timeout_ms: ^max}} = validate(%{"command" => "x", "timeout_ms" => max + 1})
      assert fields(%{"command" => "x", "timeout_ms" => 0}) == ["timeout_ms"]
      assert fields(%{"command" => "x", "timeout_ms" => "10"}) == ["timeout_ms"]
      assert fields(%{"command" => "x", "timeout_ms" => 1.5}) == ["timeout_ms"]
    end

    test "command and argv are exclusive, and one is required" do
      assert fields(%{"command" => "x", "argv" => ["y"]}) == ["command", "argv"]
      assert fields(%{}) == ["command", "argv"]
    end

    test "command must be a non-empty string" do
      assert fields(%{"command" => ""}) == ["command"]
      assert fields(%{"command" => ["ls"]}) == ["command"]
    end

    test "argv must be a non-empty list of strings" do
      assert {:ok, %{argv: ["mix", "test"]}} = validate(%{"argv" => ["mix", "test"]})
      assert fields(%{"argv" => []}) == ["argv"]
      assert fields(%{"argv" => ["mix", 1]}) == ["argv"]
      assert fields(%{"argv" => "mix test"}) == ["argv"]
    end

    test "env names must be shell identifiers and values strings" do
      assert {:ok, %{env: [{"A", "1"}, {"_B2", ""}]}} =
               validate(%{"command" => "x", "env" => %{"_B2" => "", "A" => "1"}})

      assert fields(%{"command" => "x", "env" => %{"1A" => "x"}}) == ["env"]
      assert fields(%{"command" => "x", "env" => %{"A-B" => "x"}}) == ["env"]
      assert fields(%{"command" => "x", "env" => %{"" => "x"}}) == ["env"]
      assert fields(%{"command" => "x", "env" => %{"A" => 1}}) == ["env"]
      assert fields(%{"command" => "x", "env" => %{"A" => nil}}) == ["env"]
      assert fields(%{"command" => "x", "env" => [["A", "1"]]}) == ["env"]
    end

    test "client-supplied GOODFLOWS_* names pass validation (the exec server overrides them)" do
      # Validation accepts them as ordinary names; ExecServer drops them and
      # sets its own paths (see SessionChannelTest, "a shell command runs in
      # /workspace with server-owned outputs").
      assert {:ok, %{env: env}} =
               validate(%{
                 "command" => "x",
                 "env" => %{"GOODFLOWS_OUTPUT" => "/tmp/x", "GOODFLOWS_REPORT_DIR" => "/tmp/y"}
               })

      assert length(env) == 2
    end

    test "cwd is relative to /workspace, without .., absolute paths, or NUL" do
      assert {:ok, %{cwd: "/workspace/app/sub"}} =
               validate(%{"command" => "x", "cwd" => "app/./sub/"})

      assert {:ok, %{cwd: "/workspace"}} = validate(%{"command" => "x", "cwd" => "."})
      assert fields(%{"command" => "x", "cwd" => "/etc"}) == ["cwd"]
      assert fields(%{"command" => "x", "cwd" => "a/../../b"}) == ["cwd"]
      assert fields(%{"command" => "x", "cwd" => ".."}) == ["cwd"]
      assert fields(%{"command" => "x", "cwd" => "a\0b"}) == ["cwd"]
      assert fields(%{"command" => "x", "cwd" => 1}) == ["cwd"]
    end

    test "collect_reports must be a boolean" do
      assert {:ok, %{collect_reports: true}} =
               validate(%{"command" => "x", "collect_reports" => true})

      assert fields(%{"command" => "x", "collect_reports" => "true"}) == ["collect_reports"]
      assert fields(%{"command" => "x", "collect_reports" => 1}) == ["collect_reports"]
    end

    test "job and step labels are strings of at most 255 bytes" do
      label = String.duplicate("a", 255)

      assert {:ok, %{job: ^label, step: "s"}} =
               validate(%{"command" => "x", "job" => label, "step" => "s"})

      assert fields(%{"command" => "x", "job" => label <> "a"}) == ["job"]
      # 128 two-byte characters: 256 bytes.
      assert fields(%{"command" => "x", "step" => String.duplicate("é", 128)}) == ["step"]
      assert fields(%{"command" => "x", "job" => 1}) == ["job"]
    end

    test "every invalid field is named" do
      assert fields(%{"command" => "", "cwd" => "/x", "timeout_ms" => -1, "job" => 3}) ==
               ["command", "cwd", "timeout_ms", "job"]
    end
  end

  describe "request caps" do
    test "argv holds at most argv_max_items items" do
      max = Execs.argv_max_items()
      assert max == 4_096
      assert {:ok, _} = validate(%{"argv" => List.duplicate("a", max)})
      assert fields(%{"argv" => List.duplicate("a", max + 1)}) == ["argv"]
    end

    test "env holds at most env_max_entries entries" do
      max = Execs.env_max_entries()
      assert max == 1_024
      env = fn n -> Map.new(1..n, &{"V#{&1}", "x"}) end
      assert {:ok, _} = validate(%{"command" => "x", "env" => env.(max)})
      assert fields(%{"command" => "x", "env" => env.(max + 1)}) == ["env"]
    end

    test "command plus env bytes are capped at request_max_bytes" do
      max = Execs.request_max_bytes()
      assert max == 262_144

      assert {:ok, _} = validate(%{"command" => String.duplicate("a", max)})
      assert fields(%{"command" => String.duplicate("a", max + 1)}) == ["command"]

      # Names and values count too: (max - 4) + 2 + 2 bytes is exactly the cap.
      command = String.duplicate("a", max - 4)
      assert {:ok, _} = validate(%{"command" => command, "env" => %{"AB" => "cd"}})

      assert fields(%{"command" => command <> "a", "env" => %{"AB" => "cd"}}) ==
               ["command", "env"]
    end

    test "argv bytes are capped at request_max_bytes" do
      half = div(Execs.request_max_bytes(), 2)

      assert {:ok, _} =
               validate(%{"argv" => [String.duplicate("a", half), String.duplicate("b", half)]})

      assert fields(%{"argv" => [String.duplicate("a", half), String.duplicate("b", half + 1)]}) ==
               ["argv"]
    end
  end
end
