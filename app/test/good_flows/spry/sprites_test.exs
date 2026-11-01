defmodule GoodFlows.Spry.SpritesTest do
  use ExUnit.Case, async: false
  use Mimic

  alias GoodFlows.Spry.Sprites, as: Wrapper

  @token "sprites_secret_token_a1b2"

  setup :set_mimic_global

  setup do
    %{client: Wrapper.client(@token)}
  end

  # Starts a fake SDK command process that sends `script` events to `owner`.
  defp fake_command(owner, script) do
    ref = make_ref()
    pid = spawn(fn -> script.(owner, ref) end)
    {:ok, %Sprites.Command{ref: ref, pid: pid, owner: owner}}
  end

  defp stub_spawn(test_pid, script) do
    stub(Sprites, :spawn, fn _sprite, "bash", ["-c", line], opts ->
      assert opts[:stderr_to_stdout]
      {:ok, command} = fake_command(self(), fn owner, ref -> script.(owner, ref, line) end)
      send(test_pid, {:command_pid, command.pid})
      {:ok, command}
    end)
  end

  describe "exists?/3" do
    test "maps found and not found", %{client: client} do
      stub(Sprites, :get_sprite, fn _client, "here" -> {:ok, %{"name" => "here"}} end)
      assert Wrapper.exists?(client, "here") == {:ok, true}

      stub(Sprites, :get_sprite, fn _client, _name -> {:error, {:not_found, %{}}} end)
      assert Wrapper.exists?(client, "gone") == {:ok, false}
    end

    test "auth and transport errors stay errors and never leak the token", %{client: client} do
      stub(Sprites, :get_sprite, fn _client, _name ->
        {:error, {:api_error, 401, %{"error" => "bad token #{@token}"}}}
      end)

      assert {:error, %{status: 401, message: message}} = Wrapper.exists?(client, "x")
      refute message =~ @token

      stub(Sprites, :get_sprite, fn _client, _name ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, %{status: nil, message: message}} = Wrapper.exists?(client, "x")
      assert message =~ "connection refused"
    end

    test "a hung lookup times out and its task is stopped", %{client: client} do
      test_pid = self()

      stub(Sprites, :get_sprite, fn _client, _name ->
        send(test_pid, {:task, self()})
        Process.sleep(:infinity)
      end)

      assert Wrapper.exists?(client, "x", timeout: 50) == {:error, :timeout}
      assert_received {:task, task}
      refute Process.alive?(task)
    end

    test "raised exceptions become errors", %{client: client} do
      stub(Sprites, :get_sprite, fn _client, _name -> raise "boom" end)
      assert {:error, %{message: "boom"}} = Wrapper.exists?(client, "x")
    end
  end

  describe "create/3 and destroy/3" do
    test "succeed and reduce errors", %{client: client} do
      stub(Sprites, :create, fn _client, "s1" -> {:ok, %Sprites.Sprite{name: "s1"}} end)
      assert Wrapper.create(client, "s1") == :ok

      stub(Sprites, :create, fn _client, _ ->
        {:error, {:api_error, 422, %{"message" => "bad"}}}
      end)

      assert Wrapper.create(client, "s1") == {:error, %{status: 422, message: "bad"}}

      stub(Sprites, :destroy, fn %Sprites.Sprite{name: "s1"} -> :ok end)
      assert Wrapper.destroy(client, "s1") == :ok
    end

    test "time out on a wall-clock deadline", %{client: client} do
      stub(Sprites, :destroy, fn _ -> Process.sleep(:infinity) end)
      assert Wrapper.destroy(client, "s1", timeout: 30) == {:error, :timeout}
    end
  end

  describe "exec/4" do
    test "returns exit code and combined output", %{client: client} do
      stub_spawn(self(), fn owner, ref, line ->
        send(owner, {:stdout, %{ref: ref}, "out:" <> line})
        send(owner, {:stderr, %{ref: ref}, " err"})
        send(owner, {:exit, %{ref: ref}, 3})
      end)

      assert Wrapper.exec(client, "s1", "echo hi") ==
               {:ok, %{exit_code: 3, output: "out:echo hi err", output_truncated: false}}
    end

    test "keeps the last 64 KiB of large output", %{client: client} do
      stub_spawn(self(), fn owner, ref, _line ->
        for i <- 1..16,
            do: send(owner, {:stdout, %{ref: ref}, String.duplicate(<<?a + i>>, 65_536)})

        send(owner, {:exit, %{ref: ref}, 0})
      end)

      assert {:ok, %{output: output, output_truncated: true}} = Wrapper.exec(client, "s1", "big")
      assert byte_size(output) == 65_536
      assert output == String.duplicate(<<?a + 16>>, 65_536)
    end

    test "continuous output cannot extend the deadline", %{client: client} do
      stub_spawn(self(), fn owner, ref, _line ->
        Stream.repeatedly(fn ->
          send(owner, {:stdout, %{ref: ref}, "tick\n"})
          Process.sleep(5)
        end)
        |> Stream.run()
      end)

      started = System.monotonic_time(:millisecond)
      assert Wrapper.exec(client, "s1", "yes", timeout: 100) == {:error, :timeout}
      assert System.monotonic_time(:millisecond) - started < 1_000

      assert_received {:command_pid, command_pid}
      refute Process.alive?(command_pid)
    end

    test "SDK errors are reduced", %{client: client} do
      stub_spawn(self(), fn owner, ref, _line ->
        send(owner, {:error, %{ref: ref}, :closed_before_exit})
      end)

      assert {:error, %{status: nil, message: message}} = Wrapper.exec(client, "s1", "x")
      assert message =~ "closed"

      stub(Sprites, :spawn, fn _, _, _, _ ->
        {:error, %Sprites.Error.APIError{status: 401, message: "unauthorized"}}
      end)

      assert Wrapper.exec(client, "s1", "x") == {:error, %{status: 401, message: "unauthorized"}}
    end

    test "a dead caller takes its task and command with it", %{client: client} do
      test_pid = self()

      stub_spawn(test_pid, fn _owner, _ref, _line -> Process.sleep(:infinity) end)

      caller = spawn(fn -> Wrapper.exec(client, "s1", "sleep", timeout: 60_000) end)
      assert_receive {:command_pid, command_pid}, 1_000
      ref = Process.monitor(command_pid)

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^command_pid, _}, 1_000
    end
  end

  describe "tail/2" do
    test "drops split UTF-8 and NUL bytes" do
      assert Wrapper.tail("ééé", 3) == {"é", true}
      assert Wrapper.tail(<<"a", 0, "b">>, 10) == {"ab", false}
    end
  end
end
