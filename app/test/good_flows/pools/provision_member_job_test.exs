defmodule GoodFlows.Pools.ProvisionMemberJobTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Pools.{
    Config,
    Credentials,
    DestroyMemberJob,
    Member,
    Members,
    Pool,
    Provisioner,
    ProvisionMemberJob,
    ResetMemberJob,
    Transfers
  }

  alias GoodFlows.Spry.Sprites, as: Wrapper

  setup :set_mimic_global

  setup do
    account = account_fixture()
    credential_fixture(account)
    project = project_fixture(account)
    pool = pool_fixture(project, %{"setup" => ["echo one", "echo two", "echo three"]})
    {:ok, credential} = Credentials.current(account.id)
    {:ok, member} = Members.admit_provision(pool, credential)
    {:ok, manifest} = Config.helper_manifest()
    artifact = Enum.find(manifest.artifacts, &(&1.arch == "x86_64"))
    test_pid = self()

    stub(PgFlow, :enqueue, fn job, input ->
      send(test_pid, {:enqueued, job, input})
      {:ok, Ecto.UUID.generate()}
    end)

    %{pool: pool, member: member, artifact: artifact, manifest: manifest, credential: credential}
  end

  defp healthy_exec(ctx, line, handshake) do
    cond do
      line == "uname -m" ->
        {:ok, %{exit_code: 0, output: "x86_64\n", output_truncated: false}}

      String.starts_with?(line, "sha256sum") ->
        {:ok,
         %{
           exit_code: 0,
           output: "#{ctx.artifact.sha256}  #{Transfers.helper_path()}\n#{handshake}\n",
           output_truncated: false
         }}

      true ->
        {:ok, %{exit_code: 0, output: "", output_truncated: false}}
    end
  end

  # A healthy Sprite: every step succeeds.
  defp stub_sprite(ctx, overrides \\ %{}) do
    test_pid = self()
    handshake = ~s({"name":"gf-transfer","version":"#{ctx.manifest.version}","protocol":1})

    stub(Wrapper, :create, fn _client, name, _opts ->
      send(test_pid, {:created, name})
      :ok
    end)

    stub(Wrapper, :exec, fn _client, _name, line, opts ->
      send(test_pid, {:exec, line})

      case Map.get(overrides, :exec) do
        fun when is_function(fun) -> fun.(line, opts)
        nil -> :default
      end
      |> case do
        :default -> healthy_exec(ctx, line, handshake)
        result -> result
      end
    end)

    stub(Wrapper, :write_file, fn _client, _name, path, bytes, _opts ->
      send(test_pid, {:wrote, path, byte_size(bytes)})
      Map.get(overrides, :write_file, :ok)
    end)

    stub(Wrapper, :create_checkpoint, fn _client, _name, opts ->
      send(test_pid, {:checkpoint, opts[:comment]})
      Map.get(overrides, :checkpoint, {:ok, "cp-golden"})
    end)
  end

  defp reload(member), do: Repo.get!(Member, member.id)

  describe "provision" do
    test "runs setup, installs and verifies the helper, checkpoints, and becomes idle", ctx do
      stub_sprite(ctx)

      assert ProvisionMemberJob.__pgflow_definition__()
      assert Provisioner.provision(ctx.member.id) == %{"result" => "idle"}

      member = reload(ctx.member)
      assert member.state == "idle"
      assert member.golden_checkpoint_id == "cp-golden"
      assert member.helper_version == Config.helper_version()
      assert member.arch == "x86_64"
      assert member.owner_id == nil

      assert_received {:created, name}
      assert name == member.name
      assert_received {:exec, "echo one"}
      assert_received {:exec, "echo two"}
      assert_received {:exec, "echo three"}
      assert_received {:wrote, path, size}
      assert path == Transfers.helper_path()
      assert size == ctx.artifact.size
      assert_received {:checkpoint, "gfp-golden:" <> rest}
      assert String.starts_with?(rest, member.id <> ":")
      refute Repo.reload!(ctx.pool).next_provision_at
    end

    test "a failing setup item stops setup, skips the checkpoint, and backs off the pool", ctx do
      stub_sprite(ctx, %{
        exec: fn
          "echo two", _opts -> {:ok, %{exit_code: 1, output: "", output_truncated: false}}
          _line, _opts -> :default
        end
      })

      reject(&Wrapper.create_checkpoint/3)

      assert Provisioner.provision(ctx.member.id) == %{"result" => "broken"}
      member = reload(ctx.member)
      assert member.state == "broken"
      assert member.last_error == "setup[1] exited with code 1"
      refute_received {:exec, "echo three"}
      refute_received {:wrote, _, _}

      pool = Repo.reload!(ctx.pool)
      assert pool.provision_failures == 1
      assert pool.next_provision_at
      assert pool.last_provision_error == "setup[1] exited with code 1"
    end

    test "a failed checkpoint makes the member broken", ctx do
      stub_sprite(ctx, %{checkpoint: {:error, %{status: 500, message: "checkpoint broke"}}})
      assert Provisioner.provision(ctx.member.id) == %{"result" => "broken"}
      assert reload(ctx.member).last_error =~ "checkpoint failed: checkpoint broke"
    end

    test "provisioning past its time budget makes the member broken", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)

      Application.put_env(
        :good_flows,
        GoodFlows.Pools,
        Keyword.put(original, :provision_timeout_ms, 60)
      )

      stub_sprite(ctx, %{
        exec: fn _line, opts ->
          Process.sleep(opts[:timeout])
          {:error, :timeout}
        end
      })

      assert Provisioner.provision(ctx.member.id) == %{"result" => "broken"}
      assert reload(ctx.member).last_error =~ ~r/timed out|time budget/
    end

    test "an unsupported architecture fails before bootstrap", ctx do
      stub_sprite(ctx, %{
        exec: fn
          "uname -m", _ -> {:ok, %{exit_code: 0, output: "riscv64\n", output_truncated: false}}
          _line, _ -> :default
        end
      })

      reject(&Wrapper.write_file/5)
      reject(&Wrapper.create_checkpoint/3)

      assert Provisioner.provision(ctx.member.id) == %{"result" => "broken"}
      assert reload(ctx.member).last_error =~ "unsupported_architecture"
    end

    test "an installed helper with the wrong checksum, protocol, or version is not checkpointed",
         ctx do
      reject(&Wrapper.create_checkpoint/3)

      for {output, error} <- [
            {"0000  x\n{\"name\":\"gf-transfer\",\"version\":\"0.1.0\",\"protocol\":1}\n",
             "checksum mismatch"},
            {"#{ctx.artifact.sha256}  x\n{\"name\":\"gf-transfer\",\"version\":\"0.1.0\",\"protocol\":2}\n",
             "incompatible transfer helper protocol"},
            {"#{ctx.artifact.sha256}  x\n{\"name\":\"gf-transfer\",\"version\":\"9.9.9\",\"protocol\":1}\n",
             "version mismatch"},
            {"#{ctx.artifact.sha256}  x\n", "did not answer the version handshake"}
          ] do
        {:ok, member} = Members.admit_provision(ctx.pool, ctx.credential)

        stub_sprite(ctx, %{
          exec: fn line, _ ->
            if String.starts_with?(line, "sha256sum"),
              do: {:ok, %{exit_code: 0, output: output, output_truncated: false}},
              else: :default
          end
        })

        assert Provisioner.provision(member.id) == %{"result" => "broken"}
        assert reload(member).last_error =~ error
      end
    end

    test "a bootstrap write over 16 MiB is refused", ctx do
      stub_sprite(ctx, %{write_file: {:error, :too_large}})
      reject(&Wrapper.create_checkpoint/3)
      assert Provisioner.provision(ctx.member.id) == %{"result" => "broken"}
      assert reload(ctx.member).last_error =~ "16 MiB"
    end

    test "a member whose setup changed before it started is retired, never made idle", ctx do
      stub_sprite(ctx)
      reject(&Wrapper.create/3)

      ctx.pool
      |> Ecto.Changeset.change(setup_version: 2, setup: ["new"])
      |> Repo.update!()

      assert Provisioner.provision(ctx.member.id) == %{"result" => "stale"}
      assert reload(ctx.member).state == "destroying"
      assert_received {:enqueued, DestroyMemberJob, %{"member_id" => _}}
    end

    test "a setup edit during provisioning keeps the old version, so the member is stale", ctx do
      stub_sprite(ctx, %{
        exec: fn
          "echo two", _ ->
            Repo.update!(Ecto.Changeset.change(ctx.pool, setup_version: 2, setup: ["x"]))
            :default

          _line, _ ->
            :default
        end
      })

      assert Provisioner.provision(ctx.member.id) == %{"result" => "idle"}
      member = reload(ctx.member)
      assert member.setup_version == 1
      assert GoodFlows.Pools.stale?(member, Repo.get!(Pool, ctx.pool.id))
    end

    test "a worker that lost its claim writes nothing", ctx do
      stub_sprite(ctx, %{
        exec: fn
          "echo one", _ ->
            Repo.update_all(Ecto.Query.where(Member, id: ^ctx.member.id),
              set: [owner_id: "someone|else|x"]
            )

            :default

          _line, _ ->
            :default
        end
      })

      assert Provisioner.provision(ctx.member.id) == %{"result" => "lost"}
      member = reload(ctx.member)
      assert member.state == "provisioning"
      assert member.owner_id == "someone|else|x"

      # A claimed member is never claimed twice.
      assert Provisioner.provision(ctx.member.id) == %{"result" => "skipped"}
    end

    test "member names are gfp- plus 16 base32 characters, retried on collision", ctx do
      assert ctx.member.name =~ ~r/\Agfp-[a-z2-7]{16}\z/

      taken = ctx.member.name
      calls = :counters.new(1, [])

      Application.put_env(:good_flows, :pool_member_name_generator, fn ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) < 3, do: taken, else: Member.generate_name()
      end)

      on_exit(fn -> Application.delete_env(:good_flows, :pool_member_name_generator) end)

      # Callers admit inside a transaction (under the pool lock), where a
      # failed INSERT would abort everything after it.
      assert {:ok, member} =
               Repo.transact(fn ->
                 {:ok, member} = Members.admit_provision(ctx.pool, ctx.credential)
                 {:ok, Repo.reload!(member)}
               end)

      assert member.name != taken
      assert member.state == "provisioning"
      assert member.credential_snapshot == ctx.credential.token
      assert :counters.get(calls, 1) == 3

      # Stored encrypted, as through Repo.insert.
      {:ok, id} = Ecto.UUID.dump(member.id)

      %{rows: [[stored]]} =
        Repo.query!("SELECT credential_snapshot FROM pool_members WHERE id = $1", [id])

      refute stored =~ ctx.credential.token
    end

    test "nothing runs while pools are disabled", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
      Application.put_env(:good_flows, GoodFlows.Pools, Keyword.put(original, :enabled, false))
      reject(&Wrapper.create/3)
      assert Provisioner.provision(ctx.member.id) == %{"result" => "disabled"}
    end
  end

  describe "reset" do
    setup ctx do
      member =
        member_fixture(ctx.pool, %{
          state: "resetting",
          golden_checkpoint_id: "cp-golden",
          lease_generation: 3
        })

      %{resetting: member}
    end

    test "restores the golden checkpoint and keeps the helper", ctx do
      test_pid = self()

      stub(Wrapper, :exec, fn _, _, line, _ ->
        send(test_pid, {:exec, line}) &&
          {:ok, %{exit_code: 0, output: "", output_truncated: false}}
      end)

      expect(Wrapper, :restore_checkpoint, fn _client, name, "cp-golden", _opts ->
        assert name == ctx.resetting.name
        :ok
      end)

      assert ResetMemberJob.__pgflow_definition__()
      assert Provisioner.reset(ctx.resetting.id) == %{"result" => "idle"}
      member = reload(ctx.resetting)
      assert member.state == "idle"
      assert member.helper_version == Config.helper_version()
      assert_received {:exec, cleanup}
      assert cleanup =~ "cleanup --state-dir #{Transfers.state_dir()}"
    end

    test "a failed or timed-out restore makes the member broken", ctx do
      stub(Wrapper, :exec, fn _, _, _, _ ->
        {:ok, %{exit_code: 0, output: "", output_truncated: false}}
      end)

      stub(Wrapper, :restore_checkpoint, fn _, _, _, _ ->
        {:error, %{status: 500, message: "nope"}}
      end)

      assert Provisioner.reset(ctx.resetting.id) == %{"result" => "broken"}
      assert reload(ctx.resetting).last_error =~ "restore failed: nope"

      other = member_fixture(ctx.pool, %{state: "resetting"})
      stub(Wrapper, :restore_checkpoint, fn _, _, _, _ -> {:error, :timeout} end)
      assert Provisioner.reset(other.id) == %{"result" => "broken"}
      assert reload(other).last_error =~ "unknown"
    end

    test "uses the member's own credential snapshot, not the account's current one", ctx do
      GoodFlows.Spry.put_credential(Repo.get!(GoodFlows.Accounts.Account, ctx.pool.account_id), %{
        "token" => "replacement_token_zzzz"
      })

      stub(Wrapper, :exec, fn client, _, _, _ ->
        assert client.token == token()
        {:ok, %{exit_code: 0, output: "", output_truncated: false}}
      end)

      stub(Wrapper, :restore_checkpoint, fn client, _, _, _ ->
        assert client.token == token()
        :ok
      end)

      assert Provisioner.reset(ctx.resetting.id) == %{"result" => "idle"}
    end
  end

  describe "destroy" do
    test "destroys the sprite and deletes the row; not_found counts as success", ctx do
      assert DestroyMemberJob.__pgflow_definition__()
      a = member_fixture(ctx.pool, %{state: "destroying"})
      b = member_fixture(ctx.pool, %{state: "destroying"})

      stub(Wrapper, :destroy, fn _client, name, _opts ->
        if name == a.name, do: :ok, else: {:error, %{status: 404, message: "gone"}}
      end)

      assert Provisioner.destroy(a.id) == %{"result" => "destroyed"}
      assert Provisioner.destroy(b.id) == %{"result" => "destroyed"}
      refute Repo.get(Member, a.id)
      refute Repo.get(Member, b.id)
    end

    test "an authorization failure keeps the row with a retry time", ctx do
      member = member_fixture(ctx.pool, %{state: "destroying"})
      stub(Wrapper, :destroy, fn _, _, _ -> {:error, %{status: 401, message: "unauthorized"}} end)

      assert Provisioner.destroy(member.id) == %{"result" => "retry"}
      member = reload(member)
      assert member.state == "destroying"
      assert member.owner_id == nil
      assert member.last_error =~ "unauthorized"
      assert member.next_attempt_at
    end

    test "repeated authorization failures abandon the member instead of retrying forever",
         ctx do
      member = member_fixture(ctx.pool, %{state: "destroying", failures: 4})
      stub(Wrapper, :destroy, fn _, _, _ -> {:error, %{status: 401, message: "unauthorized"}} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Provisioner.destroy(member.id) == %{"result" => "abandoned"}
        end)

      member = reload(member)
      assert member.state == "abandoned"
      assert member.last_error =~ "unauthorized"
      assert log =~ member.name

      # Other failures keep retrying however often they happened.
      other = member_fixture(ctx.pool, %{state: "destroying", failures: 9})
      stub(Wrapper, :destroy, fn _, _, _ -> {:error, %{status: 500, message: "oops"}} end)
      assert Provisioner.destroy(other.id) == %{"result" => "retry"}
    end

    test "reset and destroy still run while pools are disabled (rollback cleanup)", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
      Application.put_env(:good_flows, GoodFlows.Pools, Keyword.put(original, :enabled, false))
      member = member_fixture(ctx.pool, %{state: "destroying"})
      stub(Wrapper, :destroy, fn _, _, _ -> :ok end)

      assert Provisioner.destroy(member.id) == %{"result" => "destroyed"}
    end
  end
end
