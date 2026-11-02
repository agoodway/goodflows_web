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

  describe "create_checkpoint/3" do
    test "returns the id of the checkpoint with the unique comment", %{client: client} do
      expect(Sprites.Checkpoint, :create_by_name, fn _client, "s1", [comment: "gfp-golden:m:n"] ->
        {:ok, [%Sprites.StreamMessage{type: "info", data: "done"}]}
      end)

      stub(Sprites, :list_checkpoints, fn %Sprites.Sprite{name: "s1"} ->
        {:ok,
         [
           %Sprites.Checkpoint{id: "cp-1", comment: "other"},
           %Sprites.Checkpoint{id: "cp-2", comment: "gfp-golden:m:n"}
         ]}
      end)

      assert Wrapper.create_checkpoint(client, "s1", comment: "gfp-golden:m:n") == {:ok, "cp-2"}
    end

    test "fails on error messages in a 2xx stream and never leaks the token", %{client: client} do
      stub(Sprites.Checkpoint, :create_by_name, fn _client, _name, _opts ->
        {:ok, [%Sprites.StreamMessage{type: "error", error: "disk full #{@token}"}]}
      end)

      reject(&Sprites.list_checkpoints/1)

      assert {:error, %{message: message}} = Wrapper.create_checkpoint(client, "s1", comment: "c")
      assert message =~ "disk full"
      refute message =~ @token
    end

    test "missing or ambiguous comment is an error", %{client: client} do
      stub(Sprites.Checkpoint, :create_by_name, fn _, _, _ -> {:ok, []} end)
      stub(Sprites, :list_checkpoints, fn _ -> {:ok, []} end)

      assert {:error, %{message: "the new checkpoint was not found"}} =
               Wrapper.create_checkpoint(client, "s1", comment: "c")

      stub(Sprites, :list_checkpoints, fn _ ->
        {:ok,
         [%Sprites.Checkpoint{id: "a", comment: "c"}, %Sprites.Checkpoint{id: "b", comment: "c"}]}
      end)

      assert {:error, %{message: message}} = Wrapper.create_checkpoint(client, "s1", comment: "c")
      assert message =~ "several"
    end

    test "a hung create is killed at the deadline", %{client: client} do
      stub(Sprites.Checkpoint, :create_by_name, fn _, _, _ -> Process.sleep(:infinity) end)

      assert Wrapper.create_checkpoint(client, "s1", comment: "c", timeout: 30) ==
               {:error, :timeout}
    end
  end

  describe "restore_checkpoint/4" do
    test "succeeds, fails on error messages, and times out", %{client: client} do
      stub(Sprites.Checkpoint, :restore_by_name, fn _client, "s1", "cp-1" ->
        {:ok, [%Sprites.StreamMessage{type: "info", data: "restored"}]}
      end)

      assert Wrapper.restore_checkpoint(client, "s1", "cp-1") == :ok

      stub(Sprites.Checkpoint, :restore_by_name, fn _, _, _ ->
        {:ok, [%Sprites.StreamMessage{type: "error", error: "nope"}]}
      end)

      assert {:error, %{message: "nope"}} = Wrapper.restore_checkpoint(client, "s1", "cp-1")

      stub(Sprites.Checkpoint, :restore_by_name, fn _, _, _ ->
        {:error, {:api_error, 500, "token #{@token} rejected"}}
      end)

      assert {:error, %{status: 500, message: message}} =
               Wrapper.restore_checkpoint(client, "s1", "cp-1")

      refute message =~ @token

      stub(Sprites.Checkpoint, :restore_by_name, fn _, _, _ -> Process.sleep(:infinity) end)
      assert Wrapper.restore_checkpoint(client, "s1", "cp-1", timeout: 30) == {:error, :timeout}
    end
  end

  describe "write_file/5" do
    test "writes up to 16 MiB inclusive and refuses larger data without a request", %{
      client: client
    } do
      test_pid = self()

      stub(Sprites.Filesystem, :write, fn %Sprites.Filesystem{}, "/usr/local/bin/x", data, opts ->
        send(test_pid, {:written, byte_size(data), opts})
        :ok
      end)

      exact = :binary.copy(<<0>>, 16_777_216)
      assert Wrapper.write_file(client, "s1", "/usr/local/bin/x", exact) == :ok
      assert_received {:written, 16_777_216, [mode: 0o755]}

      assert Wrapper.write_file(client, "s1", "/usr/local/bin/x", exact <> <<0>>) ==
               {:error, :too_large}

      refute_received {:written, _, _}

      stub(Sprites.Filesystem, :write, fn _, _, _, _ -> {:error, {:api_error, 413, %{}}} end)
      assert {:error, %{status: 413}} = Wrapper.write_file(client, "s1", "/x", "a")
    end
  end

  describe "collect/4" do
    alias GoodFlows.Pools.TransferProtocol

    defp stub_collect(test_pid, script) do
      stub(Sprites, :spawn, fn _sprite, "gf-transfer", ["collect" | _], opts ->
        assert opts[:tty] == false
        {:ok, command} = fake_command(self(), script)
        send(test_pid, {:command_pid, command.pid})
        {:ok, command}
      end)
    end

    test "decodes binary outputs and the manifest, ignoring stderr", %{client: client} do
      outputs = <<0, 255, 1, "x">>

      frame =
        IO.iodata_to_binary(
          TransferProtocol.encode!(
            %{
              type: "collect",
              outputs_present: true,
              outputs_truncated: true,
              reports: [%{"name" => "a.jsonl", "size" => 3, "too_large" => false}],
              reports_truncated: false,
              reports_skipped: 4
            },
            outputs
          )
        )

      stub_collect(self(), fn owner, ref ->
        <<a::binary-size(5), b::binary>> = frame
        send(owner, {:stdout, %{ref: ref}, a})
        send(owner, {:stderr, %{ref: ref}, "diagnostic"})
        send(owner, {:stdout, %{ref: ref}, b})
        send(owner, {:exit, %{ref: ref}, 0})
      end)

      assert {:ok, result} = Wrapper.collect(client, "s1", ["gf-transfer", "collect"])
      assert result.outputs == outputs
      assert result.outputs_truncated
      assert [%{"name" => "a.jsonl"}] = result.reports
      assert result.reports_skipped == 4
    end

    test "a non-zero exit or malformed frame is an error", %{client: client} do
      stub_collect(self(), fn owner, ref ->
        send(owner, {:stderr, %{ref: ref}, "boom #{@token}"})
        send(owner, {:exit, %{ref: ref}, 2})
      end)

      assert {:error, %{message: message}} =
               Wrapper.collect(client, "s1", ["gf-transfer", "collect"])

      assert message =~ "exited with 2"
      refute message =~ @token

      stub_collect(self(), fn owner, ref ->
        send(owner, {:stdout, %{ref: ref}, "garbage"})
        send(owner, {:exit, %{ref: ref}, 0})
      end)

      assert {:error, %{message: message}} =
               Wrapper.collect(client, "s1", ["gf-transfer", "collect"])

      assert message =~ "malformed"
    end
  end

  describe "spawn_streaming/6 and transfer/5" do
    defp stub_stream(test_pid, script) do
      stub(Sprites, :spawn, fn _sprite, command, args, opts ->
        send(test_pid, {:spawn_opts, command, args, opts})
        {:ok, command} = fake_command(self(), script)
        send(test_pid, {:command_pid, command.pid})
        {:ok, command}
      end)
    end

    test "returns at once and forwards stdout, stderr, and exit separately", %{client: client} do
      stub_stream(self(), fn owner, ref ->
        send(owner, {:stdout, %{ref: ref}, <<0, 255>>})
        send(owner, {:stderr, %{ref: ref}, "err"})
        send(owner, {:stdout, %{ref: ref}, "out"})
        send(owner, {:exit, %{ref: ref}, 7})
      end)

      assert {:ok, %{ref: ref}} =
               Wrapper.spawn_streaming(client, "s1", "sh", ["-c", "x"], self(),
                 env: [{"A", "1"}],
                 dir: "/workspace"
               )

      assert_receive {:spawn_opts, "sh", ["-c", "x"], opts}
      assert opts[:stdin] == false
      assert opts[:tty] == false
      assert opts[:env] == [{"A", "1"}]
      assert opts[:dir] == "/workspace"

      assert_receive {:sprites_stream, ^ref, {:stdout, <<0, 255>>}}
      assert_receive {:sprites_stream, ^ref, {:stderr, "err"}}
      assert_receive {:sprites_stream, ^ref, {:stdout, "out"}}
      assert_receive {:sprites_stream, ^ref, {:exit, 7}}
    end

    test "transfer streams cap stderr and kill a command past its stdout budget", %{
      client: client
    } do
      stub_stream(self(), fn owner, ref ->
        send(owner, {:stderr, %{ref: ref}, :binary.copy("e", 70)})
        send(owner, {:stderr, %{ref: ref}, "more"})
        send(owner, {:stdout, %{ref: ref}, :binary.copy("o", 60)})
        send(owner, {:stdout, %{ref: ref}, :binary.copy("o", 60)})
        Process.sleep(:infinity)
      end)

      {:ok, %{ref: ref}} =
        Wrapper.transfer(client, "s1", ["gf-transfer", "send"], self(),
          timeout: 5_000,
          stdout_limit: 100,
          stderr_limit: 50
        )

      assert_receive {:command_pid, command_pid}
      monitor = Process.monitor(command_pid)
      assert_receive {:sprites_stream, ^ref, {:stderr, stderr}}
      assert byte_size(stderr) == 50
      assert_receive {:sprites_stream, ^ref, {:stdout, _first}}
      assert_receive {:sprites_stream, ^ref, {:error, %{message: message}}}
      assert message =~ "budget"
      assert_receive {:DOWN, ^monitor, :process, _, _}
      refute_received {:sprites_stream, ^ref, {:stderr, _}}
    end

    test "transfer opens stdin without a TTY and splits writes into 64 KiB frames", %{
      client: client
    } do
      test_pid = self()

      stub(Sprites, :write, fn %Sprites.Command{}, data ->
        send(test_pid, {:stdin, byte_size(data)})
        :ok
      end)

      stub(Sprites, :close_stdin, fn %Sprites.Command{} ->
        send(test_pid, :eof)
        :ok
      end)

      stub_stream(test_pid, fn _owner, _ref -> Process.sleep(:infinity) end)

      assert {:ok, stream} =
               Wrapper.transfer(client, "s1", ["gf-transfer", "receive"], self(), timeout: 5_000)

      assert_receive {:spawn_opts, "gf-transfer", ["receive"], opts}
      assert opts[:stdin] == true
      assert opts[:tty] == false

      assert Wrapper.write_stream(stream, :binary.copy(<<1>>, 150_000)) == :ok
      assert_receive {:stdin, 65_536}
      assert_receive {:stdin, 65_536}
      assert_receive {:stdin, 18_928}

      # Synchronous: the SDK was asked to close stdin before this returns.
      assert Wrapper.close_stream_stdin(stream) == :ok
      assert_received :eof

      assert Wrapper.stop_stream(stream)
      assert_receive {:command_pid, command_pid}
      ref = Process.monitor(command_pid)
      assert_receive {:DOWN, ^ref, :process, ^command_pid, _}, 1_000
      assert Wrapper.write_stream(stream, "x") == {:error, :closed}
    end

    test "the hard deadline holds despite continuous output", %{client: client} do
      stub_stream(self(), fn owner, ref ->
        Stream.repeatedly(fn ->
          send(owner, {:stdout, %{ref: ref}, "tick"})
          Process.sleep(5)
        end)
        |> Stream.run()
      end)

      {:ok, %{ref: ref}} = Wrapper.spawn_streaming(client, "s1", "yes", [], self(), timeout: 50)
      assert_receive {:sprites_stream, ^ref, {:error, :timeout}}, 1_000
      assert_receive {:command_pid, command_pid}
      ref = Process.monitor(command_pid)
      assert_receive {:DOWN, ^ref, :process, ^command_pid, _}, 1_000
    end

    test "a dead owner takes the stream and its command with it", %{client: client} do
      test_pid = self()
      stub_stream(test_pid, fn _owner, _ref -> Process.sleep(:infinity) end)

      owner =
        spawn(fn ->
          {:ok, stream} =
            Wrapper.spawn_streaming(client, "s1", "sleep", [], self(), timeout: 60_000)

          send(test_pid, {:stream, stream})
          Process.sleep(:infinity)
        end)

      assert_receive {:stream, %{pid: task}}
      assert_receive {:command_pid, command_pid}, 1_000
      task_ref = Process.monitor(task)
      command_ref = Process.monitor(command_pid)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 1_000
      assert_receive {:DOWN, ^command_ref, :process, ^command_pid, _}, 1_000
    end

    test "spawn errors are reduced with the token scrubbed", %{client: client} do
      stub(Sprites, :spawn, fn _, _, _, _ ->
        {:error, %Sprites.Error.APIError{status: 401, message: "bad #{@token}"}}
      end)

      {:ok, %{ref: ref}} = Wrapper.transfer(client, "s1", ["gf-transfer", "send"], self())
      assert_receive {:sprites_stream, ^ref, {:error, %{status: 401, message: message}}}
      refute message =~ @token
    end
  end

  describe "tail/2" do
    test "drops split UTF-8 and NUL bytes" do
      assert Wrapper.tail("ééé", 3) == {"é", true}
      assert Wrapper.tail(<<"a", 0, "b">>, 10) == {"ab", false}
    end
  end
end
