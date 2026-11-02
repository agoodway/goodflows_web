defmodule GoodFlows.Pools.TransfersTest do
  # Runs the real gf-transfer helper locally in place of a Sprite.
  use ExUnit.Case, async: false
  use Mimic

  alias GoodFlows.FakeSprite
  alias GoodFlows.Pools.{Exec, Member, TransferProtocol, Transfers}
  alias GoodFlows.Spry.Sprites, as: Wrapper

  @moduletag :helper_binary

  setup :set_mimic_global

  setup do
    original = Application.get_env(:good_flows, GoodFlows.Pools)
    on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)

    Application.put_env(
      :good_flows,
      GoodFlows.Pools,
      Keyword.merge(original, workspace_max_bytes: 64 * 1_048_576, transfer_chunk_bytes: 65_536)
    )

    root = FakeSprite.root!()

    %{
      root: root,
      client: Wrapper.client("sprites_secret_token_a1b2"),
      session_id: Ecto.UUID.generate(),
      deadline: System.os_time(:millisecond) + 600_000
    }
  end

  defp member(name \\ "gfp-test", generation \\ 1),
    do: %Member{id: Ecto.UUID.generate(), name: name, lease_generation: generation}

  # A gzip tar with a few files, including a 2+ MiB binary one.
  defp workspace!(root) do
    src = Path.join(root, "src")
    File.mkdir_p!(Path.join(src, "lib"))
    big = :crypto.strong_rand_bytes(2_200_000)
    File.write!(Path.join(src, "lib/big.bin"), big)
    File.write!(Path.join(src, "README"), "hello\n")
    File.ln_s!("lib/big.bin", Path.join(src, "link"))
    path = Path.join(root, "workspace.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [{~c"README", ~c"#{src}/README"}, {~c"lib", ~c"#{src}/lib"}, {~c"link", ~c"#{src}/link"}],
        [:compressed]
      )

    bytes = File.read!(path)
    %{path: path, size: byte_size(bytes), sha: :crypto.hash(:sha256, bytes), big: big}
  end

  test "a multi-chunk workspace is delivered, verified, and extracted", ctx do
    FakeSprite.stub!(ctx.root)
    workspace = workspace!(ctx.root)
    member = member()

    assert :ok =
             Transfers.receive_workspace(
               ctx.client,
               member,
               ctx.session_id,
               workspace,
               ctx.deadline
             )

    extracted = FakeSprite.path(ctx.root, member.name, "/workspace")
    assert File.read!(Path.join(extracted, "lib/big.bin")) == workspace.big
    assert File.read!(Path.join(extracted, "README")) == "hello\n"
    assert {:ok, "lib/big.bin"} = File.read_link(Path.join(extracted, "link"))
  end

  test "an interrupted workspace transfer resumes from the helper's committed offset", ctx do
    # The first two invocations die after 6 stdin writes (open + 5 chunks).
    FakeSprite.stub!(ctx.root, interrupt_after_writes: {6, 2})
    workspace = workspace!(ctx.root)
    member = member()
    test_pid = self()

    Mimic.stub(Wrapper, :write_stream, fn stream, data, timeout ->
      data = IO.iodata_to_binary(data)

      case TransferProtocol.decode(data) do
        {:ok, [%{header: %{"type" => "chunk", "offset" => offset}}], ""} ->
          send(test_pid, {:chunk, offset})

        _other ->
          :ok
      end

      Mimic.call_original(Wrapper, :write_stream, [stream, data, timeout])
    end)

    assert :ok =
             Transfers.receive_workspace(
               ctx.client,
               member,
               ctx.session_id,
               workspace,
               ctx.deadline
             )

    offsets = collect_offsets([])
    # Resumed attempts start where the previous one's acknowledged data ended
    # instead of from 0, and nothing is sent twice beyond the lost chunk.
    assert Enum.count(offsets, &(&1 == 0)) == 1
    assert length(offsets) < 2 * div(workspace.size + 65_535, 65_536)

    extracted = FakeSprite.path(ctx.root, member.name, "/workspace")

    assert :crypto.hash(:sha256, File.read!(Path.join(extracted, "lib/big.bin"))) ==
             :crypto.hash(:sha256, workspace.big)
  end

  defp collect_frames(acc) do
    receive do
      {:frame, type} -> collect_frames([type | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_offsets(acc) do
    receive do
      {:chunk, offset} -> collect_offsets([offset | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a lost completion reply is retried without extracting twice", ctx do
    # Chunks of 65,000 bytes keep every frame within one 64 KiB stdin write,
    # so the fake's write count equals the frame count.
    original = Application.get_env(:good_flows, GoodFlows.Pools)

    Application.put_env(
      :good_flows,
      GoodFlows.Pools,
      Keyword.put(original, :transfer_chunk_bytes, 65_000)
    )

    workspace = workspace!(ctx.root)
    chunks = div(workspace.size + 64_999, 65_000)
    # open + chunks + finish are delivered; the complete reply is lost.
    FakeSprite.stub!(ctx.root, cut_after_writes: {chunks + 2, 1})
    member = member()
    test_pid = self()

    Mimic.stub(Wrapper, :write_stream, fn stream, data, timeout ->
      data = IO.iodata_to_binary(data)

      case TransferProtocol.decode(data) do
        {:ok, [%{header: %{"type" => type}}], ""} -> send(test_pid, {:frame, type})
        _other -> :ok
      end

      Mimic.call_original(Wrapper, :write_stream, [stream, data, timeout])
    end)

    assert :ok =
             Transfers.receive_workspace(
               ctx.client,
               member,
               ctx.session_id,
               workspace,
               ctx.deadline
             )

    frames = collect_frames([])
    # The retry reopened a completed transfer: open and finish only, no chunk
    # resent, so nothing was extracted a second time.
    assert Enum.count(frames, &(&1 == "chunk")) == chunks
    assert Enum.count(frames, &(&1 == "open")) == 2
    assert Enum.count(frames, &(&1 == "finish")) == 2

    extracted = FakeSprite.path(ctx.root, member.name, "/workspace")
    marker = Path.join(extracted, "README")
    assert File.read!(marker) == "hello\n"
  end

  test "a missing helper is reported as such", ctx do
    FakeSprite.stub!(ctx.root, missing_helper: true)
    workspace = workspace!(ctx.root)

    assert Transfers.receive_workspace(
             ctx.client,
             member(),
             ctx.session_id,
             workspace,
             ctx.deadline
           ) ==
             {:error, :helper_missing}
  end

  test "a whole-file hash mismatch requires a restart and publishes nothing", ctx do
    FakeSprite.stub!(ctx.root)
    workspace = %{workspace!(ctx.root) | sha: :crypto.hash(:sha256, "something else")}
    member = member()

    assert {:error, "restart_required"} =
             Transfers.receive_workspace(
               ctx.client,
               member,
               ctx.session_id,
               workspace,
               ctx.deadline
             )

    refute File.exists?(Path.join(FakeSprite.path(ctx.root, member.name, "/workspace"), "README"))
  end

  test "exhausted retries end the transfer", ctx do
    FakeSprite.stub!(ctx.root, interrupt_after_writes: {2, 100})
    workspace = workspace!(ctx.root)

    assert {:error, "transfer retries exhausted" <> _} =
             Transfers.receive_workspace(
               ctx.client,
               member(),
               ctx.session_id,
               workspace,
               ctx.deadline
             )
  end

  test "no attempt starts once the lease fence fails, retries included", ctx do
    FakeSprite.stub!(ctx.root, interrupt_after_writes: {2, 100})
    workspace = workspace!(ctx.root)
    test_pid = self()
    checks = :counters.new(1, [])

    # The first attempt is interrupted; before the retry the member is
    # released (the fence turns false).
    fence = fn ->
      :counters.add(checks, 1, 1)
      :counters.get(checks, 1) == 1
    end

    Mimic.stub(Wrapper, :transfer, fn client, sprite, argv, owner, opts ->
      send(test_pid, :attempt)
      Mimic.call_original(Wrapper, :transfer, [client, sprite, argv, owner, opts])
    end)

    assert Transfers.receive_workspace(
             ctx.client,
             member(),
             ctx.session_id,
             workspace,
             ctx.deadline,
             fence: fence
           ) == {:error, "lease lost"}

    assert_received :attempt
    refute_received :attempt
    assert :counters.get(checks, 1) == 2
  end

  test "a hostile archive is refused by the helper too", ctx do
    FakeSprite.stub!(ctx.root)
    path = Path.join(ctx.root, "evil.tar.gz")
    src = Path.join(ctx.root, "evil")
    File.mkdir_p!(src)
    File.ln_s!("../../../etc", Path.join(src, "out"))
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"out", ~c"#{src}/out"}], [:compressed])
    bytes = File.read!(path)
    workspace = %{path: path, size: byte_size(bytes), sha: :crypto.hash(:sha256, bytes)}

    assert {:error, "archive_rejected"} =
             Transfers.receive_workspace(
               ctx.client,
               member(),
               ctx.session_id,
               workspace,
               ctx.deadline
             )
  end

  describe "fetch_report/5" do
    setup ctx do
      member = member()
      exec = %Exec{id: Ecto.UUID.generate(), session_id: ctx.session_id, lease_generation: 1}
      reports = FakeSprite.path(ctx.root, member.name, "/tmp/gf-exec-#{exec.id}/reports")
      File.mkdir_p!(reports)
      bytes = :crypto.strong_rand_bytes(300_000)
      File.write!(Path.join(reports, "a.jsonl"), bytes)

      %{
        member: member,
        exec: exec,
        reports: reports,
        bytes: bytes,
        dir: Path.join(ctx.root, "spool")
      }
    end

    test "downloads and verifies a report into the spool", ctx do
      FakeSprite.stub!(ctx.root)

      assert {:ok, %{path: path, size: 300_000, sha256: sha}} =
               Transfers.fetch_report(
                 ctx.client,
                 ctx.member,
                 ctx.exec,
                 "a.jsonl",
                 ctx.dir,
                 ctx.deadline
               )

      assert File.read!(path) == ctx.bytes
      assert sha == Base.encode16(:crypto.hash(:sha256, ctx.bytes), case: :lower)

      # A repeat request reuses the verified spool without a transfer.
      reject(&Sprites.spawn/4)

      assert {:ok, %{path: ^path}} =
               Transfers.fetch_report(
                 ctx.client,
                 ctx.member,
                 ctx.exec,
                 "a.jsonl",
                 ctx.dir,
                 ctx.deadline
               )
    end

    test "an interrupted download resumes against the same immutable snapshot", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Pools)

      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.put(original, :transfer_attempts, 1)
      )

      # open, ready, then 3 acks; the 4th ack write drops the connection.
      FakeSprite.stub!(ctx.root, interrupt_after_writes: {5, 1})

      assert {:error, :transfer_failed} =
               Transfers.fetch_report(
                 ctx.client,
                 ctx.member,
                 ctx.exec,
                 "a.jsonl",
                 ctx.dir,
                 ctx.deadline
               )

      # The source changes after the snapshot; the resumed transfer still
      # delivers the snapshot's bytes.
      File.write!(Path.join(ctx.reports, "a.jsonl"), "changed")
      Application.put_env(:good_flows, GoodFlows.Pools, original)

      assert {:ok, %{path: path}} =
               Transfers.fetch_report(
                 ctx.client,
                 ctx.member,
                 ctx.exec,
                 "a.jsonl",
                 ctx.dir,
                 ctx.deadline
               )

      assert File.read!(path) == ctx.bytes
    end

    test "spooled progress bound to another snapshot is refused, then restarts", ctx do
      FakeSprite.stub!(ctx.root)
      key = "a.jsonl" |> TransferProtocol.sha256_hex() |> binary_part(0, 16)
      File.mkdir_p!(ctx.dir)
      File.write!(Path.join(ctx.dir, key <> ".part"), "stale")

      File.write!(
        Path.join(ctx.dir, key <> ".json"),
        Jason.encode!(%{"length" => 5, "sha256" => String.duplicate("0", 64), "committed" => 5})
      )

      assert Transfers.fetch_report(
               ctx.client,
               ctx.member,
               ctx.exec,
               "a.jsonl",
               ctx.dir,
               ctx.deadline
             ) ==
               {:error, :transfer_failed}

      refute File.exists?(Path.join(ctx.dir, key <> ".json"))

      assert {:ok, %{path: path}} =
               Transfers.fetch_report(
                 ctx.client,
                 ctx.member,
                 ctx.exec,
                 "a.jsonl",
                 ctx.dir,
                 ctx.deadline
               )

      assert File.read!(path) == ctx.bytes
    end

    test "symlinked and oversized reports are refused", ctx do
      FakeSprite.stub!(ctx.root)
      File.ln_s!("a.jsonl", Path.join(ctx.reports, "b.jsonl"))

      assert Transfers.fetch_report(
               ctx.client,
               ctx.member,
               ctx.exec,
               "b.jsonl",
               ctx.dir,
               ctx.deadline
             ) ==
               {:error, :not_found}

      big = Path.join(ctx.reports, "c.jsonl")
      {:ok, file} = :file.open(big, [:write, :raw])
      {:ok, _} = :file.position(file, 33_554_433)
      :ok = :file.truncate(file)
      :ok = :file.close(file)

      assert Transfers.fetch_report(
               ctx.client,
               ctx.member,
               ctx.exec,
               "c.jsonl",
               ctx.dir,
               ctx.deadline
             ) ==
               {:error, :not_found}
    end
  end

  @tag :slow
  test "a workspace larger than the 16 MiB write limit is delivered and verified", ctx do
    FakeSprite.stub!(ctx.root)
    src = Path.join(ctx.root, "big-src")
    File.mkdir_p!(src)
    blob = :crypto.strong_rand_bytes(20 * 1_048_576 + 7)
    File.write!(Path.join(src, "blob.bin"), blob)
    path = Path.join(ctx.root, "big.tar.gz")

    :ok =
      :erl_tar.create(String.to_charlist(path), [{~c"blob.bin", ~c"#{src}/blob.bin"}], [
        :compressed
      ])

    bytes = File.read!(path)
    assert byte_size(bytes) > 16_777_216
    workspace = %{path: path, size: byte_size(bytes), sha: :crypto.hash(:sha256, bytes)}
    member = member()

    assert :ok =
             Transfers.receive_workspace(
               ctx.client,
               member,
               ctx.session_id,
               workspace,
               ctx.deadline
             )

    extracted = FakeSprite.path(ctx.root, member.name, "/workspace/blob.bin")
    assert :crypto.hash(:sha256, File.read!(extracted)) == :crypto.hash(:sha256, blob)
  end

  test "no attempt starts once the deadline has passed", ctx do
    reject(&Sprites.spawn/4)
    past = System.os_time(:millisecond) - 1

    assert Transfers.receive_workspace(
             ctx.client,
             member(),
             ctx.session_id,
             workspace!(ctx.root),
             past
           ) ==
             {:error, "session deadline passed"}
  end

  test "no whole-file SDK filesystem write or read is used", ctx do
    FakeSprite.stub!(ctx.root)
    reject(&Sprites.Filesystem.write/4)
    reject(&Sprites.Filesystem.read/2)

    assert :ok =
             Transfers.receive_workspace(
               ctx.client,
               member(),
               ctx.session_id,
               workspace!(ctx.root),
               ctx.deadline
             )
  end

  describe "with a scripted helper" do
    alias GoodFlows.Pools.TransferProtocol, as: P

    # A fake helper process driven by `script.(owner, ref, frames_in)`.
    defp scripted(script) do
      test_pid = self()

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, opts ->
        assert opts[:stdin] == true and opts[:tty] == false
        ref = make_ref()
        owner = self()
        pid = spawn(fn -> script.(owner, ref, test_pid) end)
        {:ok, %Sprites.Command{ref: ref, pid: pid, owner: owner}}
      end)

      stub(Sprites, :write, fn %Sprites.Command{pid: pid}, data ->
        send(pid, {:in, IO.iodata_to_binary(data)})
        :ok
      end)

      stub(Sprites, :close_stdin, fn _ -> :ok end)
    end

    defp next_frame(buffer \\ "") do
      case P.decode(buffer) do
        {:ok, [frame | _], rest} ->
          {frame, rest}

        {:ok, [], rest} ->
          receive do
            {:in, data} -> next_frame(rest <> data)
          end
      end
    end

    defp out(owner, ref, header, payload \\ ""),
      do: send(owner, {:stdout, %{ref: ref}, IO.iodata_to_binary(P.encode!(header, payload))})

    test "stderr never reaches the decoder and one chunk is in flight until acked", ctx do
      path = Path.join(ctx.root, "w.tar.gz")
      bytes = :crypto.strong_rand_bytes(200_000)
      File.write!(path, bytes)
      workspace = %{path: path, size: 200_000, sha: :crypto.hash(:sha256, bytes)}

      scripted(fn owner, ref, test_pid ->
        {%{header: open}, rest} = next_frame()
        # Garbage on stderr, shaped like a frame prefix, must be ignored.
        send(owner, {:stderr, %{ref: ref}, <<0, 0, 0, 5, "junk!">>})

        out(owner, ref, %{
          type: "ready",
          transfer_id: open["transfer_id"],
          committed_offset: 0,
          max_payload: 65_536,
          completed: false
        })

        {%{header: %{"type" => "chunk", "offset" => 0}}, rest} = next_frame(rest)

        # Hold the ack: no second chunk may arrive meanwhile.
        receive do
          {:in, _data} -> send(test_pid, :second_chunk_before_ack)
        after
          100 -> send(test_pid, :waited)
        end

        loop = fn loop, rest, offset ->
          out(owner, ref, %{
            type: "ack",
            transfer_id: open["transfer_id"],
            committed_offset: offset
          })

          case next_frame(rest) do
            {%{header: %{"type" => "chunk"}, payload: payload}, rest} ->
              loop.(loop, rest, offset + byte_size(payload))

            {%{header: %{"type" => "finish"}}, _rest} ->
              out(owner, ref, %{
                type: "complete",
                transfer_id: open["transfer_id"],
                length: 200_000,
                sha256: open["sha256"],
                extracted: true
              })
          end
        end

        loop.(loop, rest, 65_536)
      end)

      assert :ok =
               Transfers.receive_workspace(
                 ctx.client,
                 member(),
                 ctx.session_id,
                 workspace,
                 ctx.deadline
               )

      assert_received :waited
      refute_received :second_chunk_before_ack
    end

    defp small_workspace(ctx) do
      path = Path.join(ctx.root, "w.tar.gz")
      File.write!(path, "x")
      %{path: path, size: 1, sha: :crypto.hash(:sha256, "x")}
    end

    defp complete_upload(owner, ref, open, rest) do
      out(owner, ref, %{
        type: "ready",
        transfer_id: open["transfer_id"],
        committed_offset: 0,
        max_payload: 65_536,
        completed: false
      })

      {%{header: %{"type" => "chunk"}}, rest} = next_frame(rest)
      out(owner, ref, %{type: "ack", transfer_id: open["transfer_id"], committed_offset: 1})
      {%{header: %{"type" => "finish"}}, rest} = next_frame(rest)

      out(owner, ref, %{
        type: "complete",
        transfer_id: open["transfer_id"],
        length: 1,
        sha256: open["sha256"],
        extracted: true
      })

      rest
    end

    test "the helper args carry the session deadline and the extract budget", ctx do
      test_pid = self()

      stub(Sprites, :spawn, fn _sprite, _cmd, args, _opts ->
        send(test_pid, {:args, args})
        {:error, %{status: 500, message: "stop here"}}
      end)

      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.merge(Application.get_env(:good_flows, GoodFlows.Pools),
          transfer_attempts: 1,
          helper_extract_timeout_ms: 123_000
        )
      )

      _ =
        Transfers.receive_workspace(
          ctx.client,
          member(),
          ctx.session_id,
          small_workspace(ctx),
          ctx.deadline
        )

      assert_received {:args, args}
      flags = args |> Enum.chunk_every(2, 1, :discard) |> Map.new(fn [k, v] -> {k, v} end)
      assert flags["--deadline-unix-ms"] == to_string(ctx.deadline)
      assert flags["--extract-timeout-ms"] == "123000"
    end

    test "the first frame may take the helper idle timeout; busy is retried", ctx do
      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.merge(Application.get_env(:good_flows, GoodFlows.Pools),
          transfer_ack_timeout_ms: 100,
          helper_idle_timeout_ms: 400,
          transfer_backoff_ms: 10
        )
      )

      calls = :counters.new(1, [])

      scripted(fn owner, ref, _test_pid ->
        :counters.add(calls, 1, 1)
        {%{header: open}, rest} = next_frame()

        if :counters.get(calls, 1) == 1 do
          out(owner, ref, %{type: "error", code: "busy", message: "lock held"})
        else
          # Longer than the ack timeout: a replacement waiting for the lock.
          Process.sleep(250)
          complete_upload(owner, ref, open, rest)
        end
      end)

      assert :ok =
               Transfers.receive_workspace(
                 ctx.client,
                 member(),
                 ctx.session_id,
                 small_workspace(ctx),
                 ctx.deadline
               )

      assert :counters.get(calls, 1) == 2
    end

    test "EOF reaches the helper before the stream is stopped", ctx do
      scripted(fn owner, ref, test_pid ->
        {%{header: open}, rest} = next_frame()
        _rest = complete_upload(owner, ref, open, rest)

        receive do
          :eof ->
            send(test_pid, :helper_saw_eof)
            send(owner, {:exit, %{ref: ref}, 0})
        end
      end)

      stub(Sprites, :close_stdin, fn %Sprites.Command{pid: pid} ->
        send(pid, :eof)
        :ok
      end)

      assert :ok =
               Transfers.receive_workspace(
                 ctx.client,
                 member(),
                 ctx.session_id,
                 small_workspace(ctx),
                 ctx.deadline
               )

      assert_received :helper_saw_eof
    end

    test "a frame of another transfer is refused", ctx do
      scripted(fn owner, ref, _test_pid ->
        {_open, _rest} = next_frame()

        out(owner, ref, %{
          type: "ready",
          transfer_id: "ws-someone-else",
          committed_offset: 0,
          max_payload: 65_536,
          completed: false
        })
      end)

      assert Transfers.receive_workspace(
               ctx.client,
               member(),
               ctx.session_id,
               small_workspace(ctx),
               ctx.deadline
             ) ==
               {:error, "metadata_mismatch"}
    end

    test "a helper speaking another protocol version counts as missing", ctx do
      path = Path.join(ctx.root, "w.tar.gz")
      File.write!(path, "x")
      workspace = %{path: path, size: 1, sha: :crypto.hash(:sha256, "x")}

      scripted(fn owner, ref, _test_pid ->
        {_open, _rest} = next_frame()
        out(owner, ref, %{type: "error", code: "unsupported_version", message: "v"})
      end)

      assert Transfers.receive_workspace(
               ctx.client,
               member(),
               ctx.session_id,
               workspace,
               ctx.deadline
             ) ==
               {:error, :helper_missing}
    end
  end
end
