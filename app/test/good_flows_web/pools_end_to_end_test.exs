defmodule GoodFlowsWeb.PoolsEndToEndTest do
  # The whole pool flow over HTTP and the channel, with Sprites stubbed by
  # GoodFlows.FakeSprite: the real gf-transfer helper and real local shell
  # commands run in a per-sprite directory instead of a VM.
  use GoodFlowsWeb.ConnCase, async: false
  use Mimic

  import GoodFlows.SpryFixtures
  import GoodFlows.TarFixtures
  import Phoenix.ChannelTest, except: [push: 3]

  alias GoodFlows.FakeSprite
  alias GoodFlows.Pools.{Config, Member, Provisioner, Reconciler}
  alias GoodFlows.Repo
  alias GoodFlows.Spry.Sprites, as: Wrapper
  alias GoodFlowsWeb.{PoolSocket, SessionChannel}

  require Ecto.Query

  @moduletag :helper_binary

  setup :api_setup
  setup :set_mimic_global

  setup ctx do
    test_pid = self()

    stub(PgFlow, :enqueue, fn job, %{"member_id" => id} ->
      send(test_pid, {:enqueued, job, id})
      {:ok, Ecto.UUID.generate()}
    end)

    credential_fixture(ctx.account)
    project_fixture(ctx.account, %{"slug" => "app"})
    %{root: FakeSprite.root!()}
  end

  # Provisioning steps other than the helper are stubbed; the helper
  # handshake runs the real binary.
  defp stub_provisioning(ctx) do
    {:ok, manifest} = Config.helper_manifest()
    artifact = Enum.find(manifest.artifacts, &(&1.arch == "x86_64"))
    helper = FakeSprite.helper_binary()

    stub(Wrapper, :create, fn _c, _name, _o -> :ok end)
    stub(Wrapper, :write_file, fn _c, _name, _path, _bytes, _o -> :ok end)
    stub(Wrapper, :create_checkpoint, fn _c, _name, _o -> {:ok, "cp-golden"} end)

    stub(Wrapper, :restore_checkpoint, fn _c, name, "cp-golden", _o ->
      send(ctx.test_pid, {:restored, name})
      :ok
    end)

    stub(Wrapper, :exec, fn _c, _name, line, _o ->
      output =
        cond do
          line == "uname -m" ->
            "x86_64\n"

          String.starts_with?(line, "sha256sum") ->
            "#{artifact.sha256}  x\n" <> elem(System.cmd(helper, ["version"]), 0)

          true ->
            ""
        end

      {:ok, %{exit_code: 0, output: output, output_truncated: false}}
    end)
  end

  defp channel_socket(ctx),
    do: socket(PoolSocket, nil, %{api_key_id: ctx.sk_key.id, account_id: ctx.account.id})

  defp exec_and_wait(socket, payload) do
    ref = Phoenix.ChannelTest.push(socket, "exec", payload)
    assert_reply ref, :ok, %{exec_id: exec_id}, 5_000
    exec_id
  end

  test "pool, warm member, session, workspace, execs with outputs and reports, resume, release, reset",
       ctx do
    ctx = Map.put(ctx, :test_pid, self())
    stub_provisioning(ctx)

    # 1. Create the pool; the reconciler warms one member and the job builds it.
    body =
      ctx.sk_conn
      |> post("/api/v1/projects/app/pools", %{
        "slug" => "ci",
        "setup" => ["echo setup"],
        "max_members" => 2
      })
      |> json_response(201)

    pool_id = body["data"]["id"]
    Reconciler.reconcile()
    assert_received {:enqueued, GoodFlows.Pools.ProvisionMemberJob, member_id}
    assert Provisioner.provision(member_id) == %{"result" => "idle"}
    member = Repo.get!(Member, member_id)
    assert member.helper_version == Config.helper_version()

    # 2. Start a session: the warm member is granted.
    session =
      ctx.sk_conn
      |> post("/api/v1/projects/app/pools/ci/sessions", %{
        "max_members" => 1,
        "acquire_timeout_ms" => 60_000
      })
      |> json_response(201)
      |> Map.fetch!("data")

    {:ok, reply, socket} = join(channel_socket(ctx), SessionChannel, session["topic"])
    assert [%{id: ^member_id, ready: false}] = reply.members

    # 3. Upload the workspace; the first transfer to the member is
    #    interrupted and resumes.
    FakeSprite.stub!(ctx.root, interrupt_after_writes: {3, 1})
    source = :crypto.strong_rand_bytes(150_000)

    archive =
      tar_gz([
        {:dir, "app"},
        {:file, "app/source.bin", source},
        {:file, "app/hello.sh", "echo hello"}
      ])

    assert ctx.sk_conn
           |> put_req_header("content-type", "application/gzip")
           |> put("/api/v1/pool-sessions/#{session["id"]}/workspace", archive)
           |> response(204)

    assert_push "member_ready", %{member_id: ^member_id}, 10_000

    workspace = FakeSprite.path(ctx.root, member.name, "/workspace")

    assert :crypto.hash(:sha256, File.read!(Path.join(workspace, "app/source.bin"))) ==
             :crypto.hash(:sha256, source)

    # 4. First exec: outputs (100 KiB, truncated), stderr, and two reports
    #    plus a symlink the manifest must skip.
    script = """
    head -c 102400 /dev/zero | tr '\\0' 'o' > "$GOODFLOWS_OUTPUT"
    printf '{"a":1}\\n' > "$GOODFLOWS_REPORT_DIR/a.jsonl"
    head -c 200000 /dev/urandom > "$GOODFLOWS_REPORT_DIR/b.jsonl"
    ln -s a.jsonl "$GOODFLOWS_REPORT_DIR/c.jsonl"
    sh hello.sh
    exit 3
    """

    first =
      exec_and_wait(socket, %{
        "member_id" => member_id,
        "command" => script,
        "cwd" => "app",
        "collect_reports" => true,
        "env" => %{"GOODFLOWS_OUTPUT" => "/etc/passwd"},
        "job" => "test"
      })

    assert_push "output", %{exec_id: ^first, seq: 0, stream: "stdout", data: hello}, 10_000
    assert Base.decode64!(hello) == "hello\n"
    assert_push "exit", %{exec_id: ^first, status: "exited", exit_code: 3} = exit, 10_000
    assert exit.outputs_truncated
    assert byte_size(Base.decode64!(exit.outputs)) == 65_537
    assert Enum.map(exit.reports.files, & &1["name"]) == ["a.jsonl", "b.jsonl"]

    # 5. Download a report; the first transfer is interrupted and resumes
    #    against the same snapshot.
    report_dir = FakeSprite.path(ctx.root, member.name, "/tmp/gf-exec-#{first}/reports")
    expected = File.read!(Path.join(report_dir, "b.jsonl"))
    FakeSprite.stub!(ctx.root, interrupt_after_writes: {4, 1})

    body = ctx.sk_conn |> get("/api/v1/pool-execs/#{first}/reports/b.jsonl") |> response(200)
    assert :crypto.hash(:sha256, body) == :crypto.hash(:sha256, expected)
    assert ctx.sk_conn |> get("/api/v1/pool-execs/#{first}/reports/c.jsonl") |> json_response(404)

    # 6. Second exec, with a socket drop in the middle and a resume.
    FakeSprite.stub!(ctx.root)

    second =
      exec_and_wait(socket, %{
        "member_id" => member_id,
        "argv" => ["sh", "-c", "echo one; sleep 0.5; echo two"]
      })

    assert_push "output", %{exec_id: ^second, seq: 0, data: one}, 10_000
    assert Base.decode64!(one) == "one\n"

    Process.unlink(socket.channel_pid)
    leave_ref = leave(socket)
    assert_reply leave_ref, :ok

    {:ok, _reply, socket} = join(channel_socket(ctx), SessionChannel, session["topic"])

    ref =
      Phoenix.ChannelTest.push(socket, "resume", %{
        "execs" => [%{"exec_id" => second, "last_seq" => 0}]
      })

    assert_reply ref, :ok
    assert_push "output", %{exec_id: ^second, seq: 1, data: two}, 10_000
    assert Base.decode64!(two) == "two\n"
    assert_push "exit", %{exec_id: ^second, status: "exited", exit_code: 0}, 10_000

    # The first exec's reports are gone once the member ran another exec.
    assert ctx.sk_conn |> get("/api/v1/pool-execs/#{first}/reports/a.jsonl") |> json_response(410)

    # 7. Release: the member resets to its golden checkpoint and is idle again.
    Process.unlink(socket.channel_pid)
    assert ctx.sk_conn |> delete("/api/v1/pool-sessions/#{session["id"]}") |> response(204)
    assert_push "session_ended", %{status: "released"}
    assert Repo.get!(Member, member_id).state == "resetting"
    assert_received {:enqueued, GoodFlows.Pools.ResetMemberJob, ^member_id}
    assert Provisioner.reset(member_id) == %{"result" => "idle"}
    assert_received {:restored, name}
    assert name == member.name

    body = ctx.sk_conn |> get("/api/v1/projects/app/pools/ci/members") |> json_response(200)
    assert [%{"state" => "idle", "stale" => false, "session_id" => nil}] = body["data"]
    assert Repo.get!(GoodFlows.Pools.Pool, pool_id)
  end
end
