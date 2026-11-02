# Resumable Sprite Transfers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved Rust helper inside each Sprite and integrate durable chunk resume with GoodFlows workspace/report transfers.

**Architecture:** Short-lived `gf-transfer receive` and `send` processes speak framed binary protocol v1 through non-TTY exec stdin/stdout. The receiver owns durable progress; immutable transfer metadata and SHA-256 bind all retries. GoodFlows retains authentication and session ownership; both sides spool to disk rather than buffer files.

**Tech Stack:** Rust standard I/O, JSON, SHA-256, gzip/tar; Elixir/Phoenix and the installed Sprites SDK through `GoodFlows.Spry.Sprites`.

**Spec:** `transfer-design.md`, `specs/sprite-transfers/spec.md`, design.md D5/D8/D12, and the pool session/exec specs in this change.

## Global Constraints

- Helper runs inside the Sprite, without a listener or Sprites credential; stdin/stdout carry protocol and stderr carries diagnostics.
- Default chunk maximum 1 MiB; header maximum 8 KiB; one chunk in flight initially; raw binary payloads.
- Header prefix is a four-byte big-endian length. Check limits before allocation, including integer overflow.
- SHA-256 per chunk and complete artifact; acknowledgement follows durable data and boundary commit.
- Workspace compressed default 256 MiB; report maximum 32 MiB; outputs maximum 65,537 bytes. Use the D13 archive defaults from `GoodFlows.Pools.Config` (tasks.md 1.2): expanded 2 GiB, 100,000 entries, 60 s validation deadline.
- Bootstrap helper bytes only through a measured <=16 MiB API request. Package/version/checksum failures prevent checkpoint/readiness.
- Resume covers GoodFlows ↔ Sprite only, within the same session/member/lease generation. Existing client HTTP hops remain unchanged.
- Follow existing owner/deadline/recovery fencing. No whole-archive SDK writes or whole-body SDK report reads.
- This is the transfer subsystem plan, not a replacement for the rest of tasks.md. Pool/session/exec infrastructure remains tracked there. Do not mark integration tasks complete before their pool prerequisites exist. Task 5 packaging precedes pool provisioning; its job integration closes with tasks.md 5.2. Task 6 follows tasks.md 6.1 and 8.2, then supplies 7.3 and 8.4.
- Do not commit, change branches, or implement the companion goodci project without separate authorization.

## Review Focus

- Fragmented or malicious lengths must not allocate beyond negotiated limits (Task 1).
- Lost acknowledgements and crashes between data/metadata/publication must preserve an authoritative resume boundary (Task 2).
- Escaping link chains, mutable reports, and disk-full extraction must not produce a ready corrupt workspace (Task 3).
- An old remote helper surviving disconnect must not race a replacement or a later lease (Tasks 4 and 6).
- Missing/incompatible helper releases and coordinator loss must fail explicitly without silent restart under another identity (Tasks 5 and 6).

## File boundaries and interfaces

- `sprite-transfer/Cargo.toml`, `src/main.rs`, `src/lib.rs`: crate/binary and CLI; commands `receive`, `send`, `collect` (bounded outputs read plus no-follow report manifest in one frame), `version`. CLI roots/metadata are server-owned arguments. Keep the runtime blocking and single-transfer; no network library is needed inside the helper.
- `sprite-transfer/src/protocol.rs`: `TransferMeta`, `Limits`, `Frame`, `FrameReader<R: Read>`, `FrameWriter<W: Write>`. Meta carries protocol version, transfer/session/member identifiers, lease generation, direction, artifact, total length and SHA-256. Frames are Open, Ready, Chunk, Ack, Finish, Complete, Error; Ready/Ack expose `committed_offset: u64`. Constructors must validate lengths and metadata.
- `sprite-transfer/src/state.rs`: `Receiver::open(root: &Path, meta: &TransferMeta, limits: &Limits) -> Result<Receiver>`, `committed_offset(&self) -> u64`, `commit_chunk(&mut self, offset: u64, data: &[u8], sha256: &[u8; 32]) -> Result<u64>`, `finish(&mut self) -> Result<CompletedArtifact>`. Receiver owns the lock, part file, and durable sidecar. `CompletedArtifact` contains path, length and complete SHA-256.
- `sprite-transfer/src/receive.rs`: `run_receive<R: Read, W: Write>(input: R, output: W, config: ReceiveConfig) -> Result<()>`; validates/delivers a received workspace under its lease generation.
- `sprite-transfer/src/send.rs`: `Snapshot::open_or_create(root: &Path, key: &TransferKey, source: &Path, max_bytes: u64) -> Result<Snapshot>` and `run_send<R: Read, W: Write>(input: R, output: W, snapshot: Snapshot, limits: Limits) -> Result<()>`. TransferKey is TransferMeta without length/hash; snapshot creation derives the immutable TransferMeta. Snapshot records fixed path/length/hash. Download open requests a snapshot by key; the helper offers metadata and waits for receiver progress before data. Receiving acknowledgements arrive on input.
- `sprite-transfer/src/archive.rs`: `validate_and_extract(archive: &Path, destination: &Path, limits: &ArchiveLimits) -> Result<()>`; disk-stage, inspect confinement/types/links and expansion bounds, then extract. `ArchiveLimits` consumes pool-config byte/entry/deadline values (defaults in design.md D13). Failed extraction is a terminal member-hydration failure.
- `sprite-transfer/tests/{protocol,resume,artifacts}.rs`: black-box library/CLI behavior; `sprite-transfer/README.md`: protocol fixtures, CLI usage and lifecycle limits.
- `app/lib/good_flows/pools/transfer_protocol.ex`: wire-compatible incremental codec, with bounded `decode(buffer, limits)` returning complete frames and unconsumed bytes or an incomplete-frame result; never concatenate unbounded buffers. `encode(frame, limits)` returns bounded iodata or an error.
- `app/lib/good_flows/pools/transfers.ex`: `receive_workspace(session, member, spool_path, opts)` and `fetch_report(session, exec, name, opts)` return `{:ok, result}` or sanitized `{:error, reason}`. Session-owner routing supplies the captured client internally. All SDK operations pass through the Sprites adapter.
- Modify `app/lib/good_flows/spry/sprites.ex`: `transfer(client, sprite_name, argv, handler, opts)` runs a bounded duplex conversation. Handler consumes stdout chunks and SDK exit, and returns bounded protocol writes/EOF plus final result. Stderr remains separate and scrubbed. The adapter owns every SDK process/write/close call and its kill guard.
- `sprite-transfer/scripts/package.sh`: release artifact/checksum/protocol metadata; `sprite-transfer/examples/transport-spike.exs`: opt-in real-Sprite >16 MiB duplex/resume verification using the server adapter. No real credential appears in fixtures or logs.
- Pool integration files are created by tasks.md: `app/lib/good_flows/pools/{config,session_coordinator,provision_member_job}.ex` and the API report controller. Add `app/test/good_flows/pools/{transfer_protocol,transfers,provision_member_job}_test.exs` and extend `app/test/good_flows/spry/sprites_test.exs`.

## Task 1: Protocol and helper entry point (tasks.md 2.1)

**Consumes:** approved protocol constants and frame vocabulary. **Produces:** protocol types, CLI version reply and incremental reader/writer used by Tasks 2–4.

- [x] Write `tests/protocol.rs` cases `binary_fragmented_roundtrip` (include NUL/non-UTF-8, split every prefix/header/payload boundary), `reject_oversized_before_allocation` (8,193-byte header, payload >1,048,576), `reject_offset_overflow`, and `reject_unknown_version`. Assert errors occur before payload reads/allocation.
- [x] Run `cargo test --manifest-path sprite-transfer/Cargo.toml --test protocol`; expect failure because the crate/interfaces do not exist.
- [x] Create the crate and protocol/CLI files above. Implement bounded FrameReader/FrameWriter and version negotiation using protocol version 1. Keep error messages free of payload contents. Lock dependency versions in Cargo.lock.
- [x] Run the protocol command again; expect all cases passing. Run `cargo fmt --manifest-path sprite-transfer/Cargo.toml -- --check`. Write/read the same documented JSON/binary fixtures in later Elixir codec tests.

## Task 2: Durable receiving state (tasks.md 2.2)

**Consumes:** Task 1 TransferMeta, Limits, Frame. **Produces:** Receiver/CompletedArtifact and deterministic reopen behavior for both helper uploads and server downloads.

- [x] Write `tests/resume.rs` cases `resume_after_lost_ack`, `truncate_uncommitted_tail`, `reject_metadata_change`, `exclusive_writer`, `bad_chunk_does_not_advance`, `bad_final_hash_never_publishes`, `finish_reply_loss_is_idempotent`, and `recover_after_publish_before_receipt`. Assert the exact committed offsets and final bytes/hash; inject failures at each filesystem durability boundary rather than sleeping.
- [x] Run `cargo test --manifest-path sprite-transfer/Cargo.toml --test resume`; expect missing state interfaces to fail.
- [x] Implement Receiver interfaces: lock transfer state, validate immutable metadata, sync part data, atomically replace/sync sidecar and parent directory, then ack. On reopen truncate beyond committed offset. Finish rehashes bounded file reads before same-filesystem publication; reconcile an already-published hash-matching file after a crash before receipt. A final hash mismatch invalidates partial state with restart-required error.
- [x] Re-run resume and protocol tests; expect all passing. Document crash semantics and lock errors in README. Workspace extraction completion remains a separate lease-fenced result: an uncertain extraction result must quarantine/reset rather than blindly extract twice.

## Task 3: Workspace receive, report send, and cleanup (tasks.md 2.3)

**Consumes:** Tasks 1–2 state/protocol. **Produces:** run_receive, Snapshot/run_send, confined extraction and the complete CLI.

- [x] Write `tests/artifacts.rs` cases `workspace_not_ready_before_finish`, `reject_archive_escape_and_special_entries`, `expansion_limits`, `disk_full_does_not_complete`, `report_snapshot_resume_is_immutable`, `report_cap_is_33554432`, `reject_report_symlink`, and `cleanup_invalidates_resume`. Include duplicate-path/link-chain archives and source mutation during snapshot creation. Assert failed extraction never records hydration success.
- [x] Run `cargo test --manifest-path sprite-transfer/Cargo.toml --test artifacts`; expect missing artifact operations to fail.
- [x] Implement receive/send/archive interfaces and private state roots outside /workspace. Use bounded copy/hash operations, no-follow regular-file opens, disk staging, and shared archive policy. Snapshot before sending; refuse mutable/oversized inputs rather than advertising unverified metadata. Keep one chunk in flight and wait for durable acknowledgement before reading the next.
- [x] Run `cargo test --manifest-path sprite-transfer/Cargo.toml` and `cargo clippy --manifest-path sprite-transfer/Cargo.toml --all-targets -- -D warnings`; expect success. Document raw send/receive examples and when state becomes invalid.

## Task 4: Elixir codec, duplex SDK adapter, and live spike (tasks.md 2.4)

**Consumes:** Task 1 fixtures and Task 3 helper. **Produces:** TransferProtocol and Sprites.transfer/5 for pool integrations.

- [x] Add ExUnit tests in `transfer_protocol_test.exs` and `sprites_test.exs`: shared fixture compatibility, fragmented streams, SDK stderr separation, bounded queued bytes, stdin EOF, no second chunk before ack, caller death, hard deadline despite active output, uncertain old owner retaining lock/fence, and token scrubbing on all errors. Use supervised processes and monitored synchronization.
- [x] From `app/`, run `mix test test/good_flows/pools/transfer_protocol_test.exs test/good_flows/spry/sprites_test.exs`; expect missing adapter/codec failures.
- [x] Implement incremental codec and the bounded conversation adapter in the files above. The adapter must not merge protocol stdout with stderr or exec ring buffers; use SDK stdin writes and EOF only through Sprites. Bound transport buffers independently of attacker-declared frame sizes. Reconnect starts a new invocation only after old-owner safety/locking checks.
- [ ] Re-run ExUnit tests; expect passing. Add the opt-in spike example and execute it with explicitly provided test Sprite access: upload and download >16 MiB random binary data, interrupt after multiple acknowledgements, invoke again, assert the receiver offset advances without restarting, and compare SHA-256. Record observed frame/memory/EOF behavior in design.md D12. If credentials are unavailable, record that live validation remains pending; stubbed tests do not prove the transport limit. **Status: the ExUnit part is done; the live run is pending (no Sprites credential was available). See design.md D12 and tasks.md 2.4 for how to run it.**

## Task 5: Package and provision compatible helpers (tasks.md 2.5 and pool provisioning)

**Consumes:** Task 3 binary; pool provision job from tasks.md. **Produces:** versioned per-architecture helper artifact and enforced checkpoint readiness.

- [x] Add packaging/provisioning tests for wrong architecture, wrong checksum, protocol mismatch, missing binary, and bootstrap bytes >16,777,216. Assert no checkpoint or idle transition occurs after any failure; after success/reset, helper version remains compatible. Build metadata must identify the actual supported Sprite architectures; do not guess runtime architecture.
- [x] Run the new provisioning tests; expect helper installation assertions to fail against unmodified provisioning.
- [x] Implement the package script and provisioning integration: release-build for supported Linux target(s), verify actual byte size and hash, install after setup, run version handshake, then checkpoint. Rebuild old helper-less members instead of marking them current. Write static musl artifacts and `manifest.json` to gitignored `app/priv/gf-transfer/<target>/` before `mix release`, detect member architecture with `uname -m` before bootstrap, and document rollback/deploy order (design.md D13).
- [x] Run `cargo build --release --manifest-path sprite-transfer/Cargo.toml`, package verification, and from `app/` `mix test test/good_flows/pools/provision_member_job_test.exs`; expect valid package artifacts and all failure guards passing. Do not deploy as part of this plan.

## Task 6: Pool spools, resume orchestration, and lifecycle integration (tasks.md 2.6, 7.3, 8.4)

**Consumes:** Task 4 adapter/codec, Task 5 installed helper, and the existing plan's session coordinator, lease fences, hydration and report endpoint. **Produces:** Transfers entry points and end-to-end readiness/download behavior.

- [x] Add `transfers_test.exs` and report controller cases: 20 MiB workspace upload/late grant, reconnect/lost ack/finish reply, two-node spool routing, immutable report resume, session deadline during retry, release/next-exec invalidating state, coordinator loss, cleanup, and absent helper. Assert per-chunk bounds, hashes, no whole-archive SDK filesystem write/read, no stale member_ready, and existing HTTP 404/410 rules.
- [x] Run targeted transfer/controller tests; expect new integration assertions to fail before orchestration exists.
- [x] Implement Transfers and coordinator/provision/controller integration using disk-backed immutable sources and durable receiver spools. Preserve the initial HTTP upload once-only rule; validate the spool first, hydrate each lease using its own transfer id, and announce readiness only after the generation-fenced helper completion. Persist a verified server report spool before serving HTTP and keep eligible results retryable until invalidation. Remove partials/snapshots before reset/reuse and terminal-session spools through the coordinator janitor.
- [x] Run `cargo test --manifest-path sprite-transfer/Cargo.toml`, `cargo fmt --manifest-path sprite-transfer/Cargo.toml -- --check`, `cargo clippy --manifest-path sprite-transfer/Cargo.toml --all-targets -- -D warnings`, and from `app/` `mix precommit`; expect success. Run `openspec validate add-sprite-pools --strict` from repository root. Document protocol and lifecycle examples alongside the tests and mark tasks complete only on observed evidence.

## Self-review and handoff

Task 1 covers helper/frame behavior; Task 2 covers identity, durability, resume and completion; Task 3 covers confinement, snapshots and invalidation; Task 4 covers real transport boundaries; Task 5 covers checkpoint-compatible delivery; Task 6 covers member/session ownership and unchanged HTTP boundaries. The live transport spike is a prerequisite for claiming production integration verified. No implementation, dependency installation, release packaging, or application tests were performed while authoring this plan.
