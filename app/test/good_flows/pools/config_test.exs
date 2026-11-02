defmodule GoodFlows.Pools.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GoodFlows.Pools.Config

  setup do
    original = Application.get_env(:good_flows, GoodFlows.Pools)

    on_exit(fn ->
      Application.put_env(:good_flows, GoodFlows.Pools, original)
      Config.load_manifest()
    end)

    %{original: original}
  end

  defp put(original, overrides),
    do: Application.put_env(:good_flows, GoodFlows.Pools, Keyword.merge(original, overrides))

  test "defaults match design D13 when nothing is configured" do
    Application.put_env(:good_flows, GoodFlows.Pools, [])

    assert Config.max_members_cap() == 32
    assert Config.provision_timeout_ms() == 30 * 60_000
    assert Config.workspace_max_bytes() == 256 * 1_048_576
    assert Config.workspace_max_expanded_bytes() == 2_147_483_648
    assert Config.workspace_max_entries() == 100_000
    assert Config.archive_validation_timeout_ms() == 60_000
    assert Config.workspace_read_timeout_ms() == 300_000
    assert Config.workspace_max_concurrent_uploads_per_account() == 1
    assert Config.transfer_chunk_bytes() == 1_048_576
    assert Config.transfer_concurrency() == 2
    assert Config.transfer_ack_timeout_ms() == 30_000
    assert Config.transfer_attempts() == 5
    assert Config.helper_idle_timeout_ms() == 60_000
    assert Config.report_fetch_timeout_ms() == 60_000
    assert Config.report_max_files() == 100
    assert Config.spool_max_bytes() == 2_147_483_648
    assert Config.spool_account_max_bytes() == 1_073_741_824
    assert Config.session_retention_ms() == 30 * 24 * 60 * 60_000
    refute Config.require_helper_manifest?()
    assert Config.spool_dir() == Path.join(System.tmp_dir!(), "goodflows-pools")
    assert Config.helper_artifact_dir() =~ "priv/gf-transfer"
    assert Config.disconnect_grace_ms() == 60_000
    assert Config.max_session_lifetime_ms() == 6 * 60 * 60_000
    assert Config.acquire_timeout_max_ms() == 10 * 60_000
    assert Config.exec_max_ms() == 60 * 60_000
    assert Config.exec_buffer_bytes() == 1_048_576
    assert Config.configured_enabled?()
    assert Config.report_max_bytes() == 33_554_432
    assert Config.outputs_max_bytes() == 65_537
    assert Config.bootstrap_max_bytes() == 16_777_216
  end

  test "the test fixture manifest enables pools" do
    assert :ok = Config.validate!()
    assert Config.enabled?()
    assert {:ok, %{protocol: 1, artifacts: [_, _]}} = Config.helper_manifest()
    assert {:ok, %{target: "x86_64-unknown-linux-musl"}} = Config.helper_artifact("x86_64\n")
    assert Config.helper_artifact("riscv64") == {:error, :unsupported_architecture}
    assert Config.helper_version() == "0.1.0+p1"
  end

  describe "helper staleness (rolling deploys and rebuilds)" do
    test "only an older helper is stale; a rebuild or a newer helper is not" do
      assert Config.helper_version() == "0.1.0+p1"

      refute Config.helper_stale?("0.1.0+p1")
      # Members recorded with a build digest (any rebuild of 0.1.0) are current.
      refute Config.helper_stale?("0.1.0+p1+0123456789abcdef")
      # A newer node's members are left alone by this (older) node.
      refute Config.helper_stale?("0.2.0+p1")
      refute Config.helper_stale?("0.1.1+p2")

      assert Config.helper_stale?("0.0.9+p1")
      assert Config.helper_stale?("0.9.0+p0")
      assert Config.helper_stale?("garbage")
      refute Config.helper_stale?(nil)
    end

    test "a helper of another protocol is never granted here" do
      assert Config.helper_compatible?("0.1.0+p1")
      assert Config.helper_compatible?("0.2.0+p1")
      refute Config.helper_compatible?("0.2.0+p2")
      refute Config.helper_compatible?(nil)
    end

    test "nothing is stale while this node has no manifest", %{original: original} do
      put(original, helper_artifact_dir: Path.join(System.tmp_dir!(), "no-such-gf-transfer"))
      capture_log(fn -> Config.validate!() end)
      refute Config.helper_stale?("0.0.1+p1")
    end
  end

  @tag :helper_binary
  test "the locally built helper matches the crate version and protocol" do
    binary = GoodFlows.FakeSprite.helper_binary()
    {output, 0} = System.cmd(binary, ["version"])
    handshake = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    [_, crate_version] =
      Regex.run(~r/^version\s*=\s*"([^"]+)"/m, File.read!("../sprite-transfer/Cargo.toml"))

    assert handshake["version"] == crate_version,
           "#{binary} is stale (#{handshake["version"]}, crate is #{crate_version}): rebuild it"

    assert handshake["protocol"] == Config.protocol_version()
  end

  test "invalid settings are refused at startup", %{original: original} do
    put(original, exec_max_ms: 0)
    assert_raise ArgumentError, ~r/exec_max_ms must be a positive integer/, &Config.validate!/0

    put(original, transfer_chunk_bytes: 2_000_000)
    assert_raise ArgumentError, ~r/transfer_chunk_bytes must be at most/, &Config.validate!/0

    put(original, provision_timeout_ms: 60 * 60_000)

    assert_raise ArgumentError, ~r/ProvisionMemberJob timeout/, fn -> Config.validate!() end

    put(original, [])

    assert_raise ArgumentError, ~r/ResetMemberJob/, fn ->
      Config.validate!(member_job_timeout_seconds: 1)
    end
  end

  test "a missing manifest stops the node when it is required", %{original: original} do
    put(original,
      helper_artifact_dir: Path.join(System.tmp_dir!(), "no-such-gf-transfer"),
      require_helper_manifest: true
    )

    assert_raise ArgumentError, ~r/POOLS_ENABLED is true but the gf-transfer helper/, fn ->
      Config.validate!()
    end

    # Switching pools off still boots.
    put(original,
      helper_artifact_dir: Path.join(System.tmp_dir!(), "no-such-gf-transfer"),
      require_helper_manifest: true,
      enabled: false
    )

    assert :ok = Config.validate!()
  end

  test "an account's spool share must admit at least one upload", %{original: original} do
    put(original, spool_account_max_bytes: 10, workspace_max_bytes: 20)
    assert_raise ArgumentError, ~r/spool_account_max_bytes/, &Config.validate!/0
  end

  test "a missing manifest disables pools without stopping the node", %{original: original} do
    put(original, helper_artifact_dir: Path.join(System.tmp_dir!(), "no-such-gf-transfer"))

    log = capture_log(fn -> assert :ok = Config.validate!() end)

    assert log =~ "Sprite pools are disabled"
    refute Config.enabled?()
    assert {:error, reason} = Config.helper_manifest()
    assert reason =~ "manifest.json"
    assert Config.helper_artifact("x86_64") == {:error, :helper_unavailable}
    assert Config.helper_version() == nil
  end

  test "a manifest whose binary does not match is invalid", %{original: original} do
    dir = Path.join(System.tmp_dir!(), "gf-transfer-bad-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "x86_64-unknown-linux-musl"))
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "x86_64-unknown-linux-musl/gf-transfer"), "bytes")

    manifest = fn sha, size, protocol ->
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "version" => "0.1.0",
          "protocol" => protocol,
          "artifacts" => [
            %{
              "target" => "x86_64-unknown-linux-musl",
              "arch" => "x86_64",
              "path" => "x86_64-unknown-linux-musl/gf-transfer",
              "sha256" => sha,
              "size" => size
            }
          ]
        })
      )
    end

    put(original, helper_artifact_dir: dir)
    good_sha = :sha256 |> :crypto.hash("bytes") |> Base.encode16(case: :lower)

    manifest.(String.duplicate("0", 64), 5, 1)
    assert {:error, reason} = Config.load_manifest()
    assert reason =~ "SHA-256 mismatch"

    manifest.(good_sha, 6, 1)
    assert {:error, reason} = Config.load_manifest()
    assert reason =~ "size mismatch"

    manifest.(good_sha, 5, 2)
    assert {:error, reason} = Config.load_manifest()
    assert reason =~ "protocol"

    manifest.(good_sha, 16_777_217, 1)
    assert {:error, reason} = Config.load_manifest()
    assert reason =~ "bootstrap limit"

    manifest.(good_sha, 5, 1)
    assert {:ok, _manifest} = Config.load_manifest()
  end

  test "POOLS_ENABLED=false disables pools", %{original: original} do
    put(original, enabled: false)
    Config.load_manifest()
    refute Config.enabled?()
  end
end
