# Opt-in live transport spike for gf-transfer over the Sprites exec WebSocket.
#
# Run from app/ against a throwaway Sprite you are allowed to destroy:
#
#     SPRITES_TOKEN=... SPIKE_SPRITE=gf-spike-$(date +%s) \
#       mix run ../sprite-transfer/examples/transport-spike.exs
#
# It creates the sprite, installs the packaged helper (scripts/package.sh
# must have run), then in both directions moves more than 16 MiB of random
# binary data through GoodFlows.Pools.Transfers (the production code path),
# interrupting the first attempt after several acknowledgements so the
# second invocation must resume from the committed offset, and compares
# SHA-256 at the end. The sprite is destroyed afterwards unless
# SPIKE_KEEP=1. The token is never printed.
#
# Record the observed frame sizes, EOF behavior, memory, and timings in
# openspec/changes/add-sprite-pools/design.md (D12).

alias GoodFlows.Pools.{Config, Exec, Member, Transfers}
alias GoodFlows.Spry.Sprites

token = System.fetch_env!("SPRITES_TOKEN")
name = System.get_env("SPIKE_SPRITE", "gf-spike-#{System.os_time(:second)}")
client = Sprites.client(token)
size = String.to_integer(System.get_env("SPIKE_BYTES", "#{20 * 1_048_576}"))
log = fn message -> IO.puts("[spike] #{message}") end

{:ok, manifest} = Config.load_manifest()
log.("helper #{manifest.version} protocol #{manifest.protocol}")

try do
  :ok = Sprites.create(client, name, timeout: 300_000)
  {:ok, %{output: arch}} = Sprites.exec(client, name, "uname -m", timeout: 60_000)
  {:ok, artifact} = Config.helper_artifact(arch)
  bytes = File.read!(Path.join(Config.helper_artifact_dir(), artifact.path))
  :ok = Sprites.write_file(client, name, Transfers.helper_path(), bytes, timeout: 120_000)
  {:ok, %{output: version}} = Sprites.exec(client, name, "#{Transfers.helper_path()} version", timeout: 60_000)
  log.("installed: #{String.trim(version)}")

  # Upload: a tar.gz holding one incompressible file of `size` bytes.
  tmp = Path.join(System.tmp_dir!(), "spike-#{System.unique_integer([:positive])}")
  File.mkdir_p!(tmp)
  payload = :crypto.strong_rand_bytes(size)
  File.write!(Path.join(tmp, "blob.bin"), payload)
  archive = Path.join(tmp, "workspace.tar.gz")
  :ok = :erl_tar.create(String.to_charlist(archive), [{~c"blob.bin", String.to_charlist(Path.join(tmp, "blob.bin"))}], [:compressed])
  archive_bytes = File.read!(archive)
  workspace = %{path: archive, size: byte_size(archive_bytes), sha: :crypto.hash(:sha256, archive_bytes)}
  member = %Member{id: Ecto.UUID.generate(), name: name, lease_generation: 1}
  session_id = Ecto.UUID.generate()
  # The session deadline every transfer and helper invocation is bound to.
  deadline = System.os_time(:millisecond) + 30 * 60_000

  # Interrupt the first attempt mid-transfer: killing its owner makes the
  # stream guard close the exec connection, like a dropped WebSocket.
  first = Task.async(fn -> Transfers.receive_workspace(client, member, session_id, workspace, deadline) end)
  Process.sleep(String.to_integer(System.get_env("SPIKE_INTERRUPT_MS", "4000")))
  Task.shutdown(first, :brutal_kill)
  log.("first upload attempt interrupted; resuming with a new invocation")

  {micros, result} = :timer.tc(fn -> Transfers.receive_workspace(client, member, session_id, workspace, deadline) end)
  log.("upload #{workspace.size} bytes: #{inspect(result)} in #{div(micros, 1000)} ms")

  {:ok, %{output: remote_sha}} =
    Sprites.exec(client, name, "sha256sum /workspace/blob.bin", timeout: 120_000)

  local_sha = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  log.("upload integrity: #{String.contains?(remote_sha, local_sha)}")

  # Download: copy the blob into a report dir and fetch it back.
  exec = %Exec{id: Ecto.UUID.generate(), session_id: session_id, lease_generation: 1}
  {:ok, _} =
    Sprites.exec(client, name, "mkdir -p /tmp/gf-exec-#{exec.id}/reports && cp /workspace/blob.bin /tmp/gf-exec-#{exec.id}/reports/r.jsonl", timeout: 120_000)

  spool = Path.join(tmp, "spool")
  first = Task.async(fn -> Transfers.fetch_report(client, member, exec, "r.jsonl", spool, deadline) end)
  Process.sleep(String.to_integer(System.get_env("SPIKE_INTERRUPT_MS", "4000")))
  Task.shutdown(first, :brutal_kill)
  log.("first download attempt interrupted; resuming from the spool's committed offset")

  {micros, result} = :timer.tc(fn -> Transfers.fetch_report(client, member, exec, "r.jsonl", spool, deadline) end)
  case result do
    {:ok, report} ->
      log.("download: #{inspect(Map.take(report, [:size, :sha256]))} in #{div(micros, 1000)} ms")

    other ->
      log.("download failed after #{div(micros, 1000)} ms: #{inspect(other)}")
  end

  log.("download integrity: #{match?({:ok, %{sha256: ^local_sha}}, result)}")
  log.("note: reports above 32 MiB are refused by design; SPIKE_BYTES above that tests the cap")
after
  unless System.get_env("SPIKE_KEEP") == "1" do
    _ = Sprites.destroy(client, name, timeout: 300_000)
    log.("destroyed #{name}")
  end
end
