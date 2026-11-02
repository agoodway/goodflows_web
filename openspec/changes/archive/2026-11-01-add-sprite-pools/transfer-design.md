# Resumable Sprite transfer helper — approved design

Status: approved 2026-11-01 and integrated into the
add-sprite-pools proposal, design, delta specs, and tasks. This replaces the
whole-archive Filesystem.write plan. Implemented in `sprite-transfer/`
(`gf-transfer`) and `GoodFlows.Pools.Transfers`; the live real-Sprite
transport spike (task 2.4) is still pending, see design.md D12.

## Intent and decisions

The user wants a small Rust CLI running inside each Sprite, handling both sending
and receiving data, with chunk-level resume after interruption. GoodFlows keeps
the Sprites token and starts the helper through the non-TTY exec WebSocket.
The helper receives bytes on stdin, sends protocol responses/data on stdout,
and writes sanitized diagnostics to stderr. It opens no listening port.

The helper lives at `sprite-transfer/` in this repository, with binary name
`gf-transfer`.

## Approaches

- Selected direction: short-lived helper over exec stdin/stdout. It uses the
  existing authenticated transport and needs no service credentials in the VM.
  Each invocation handles one transfer; reconnect starts another invocation.
- Alternative: a persistent HTTP service inside the Sprite. This offers an
  independent transfer endpoint but adds authentication, routing, and service
  lifecycle work without a demonstrated need.
- Existing whole-file filesystem API approach: unsuitable for the intended
  256 MiB workspace archive because the documented write-request maximum is
  16 MiB. Exec transport behavior still needs an integration spike.

Reference: https://docs.fly.io/sprites/api/filesystem/write-file
Reference: https://docs.fly.io/sprites/api/websockets/execute-command

## Scope

Implement `gf-transfer receive` and `gf-transfer send`, plus a version handshake.
Commands are invoked by GoodFlows using server-owned argv and paths. The helper
requires no HTTP client or knowledge of a Sprites token. The server controls
session authorization, lease generation, resource limits, and expiry.

Workspace delivery is resumable from the GoodFlows session spool to each Sprite.
Report retrieval is resumable from the Sprite to a GoodFlows temporary spool.
The existing initial goodci-to-GoodFlows upload remains a single HTTP upload;
resuming that separate hop is outside this design. Resume does not survive a
session ending, a member reset, or the loss of the session coordinator/spool.

## Transport and framing

Protocol version 1 uses length-delimited frames independent of WebSocket message
boundaries. Each frame has a 4-byte big-endian header length, a UTF-8 JSON header,
and exactly the declared number of raw payload bytes. Header length is capped
at 8 KiB before allocation. Payloads are capped at a negotiated maximum of
1 MiB per chunk by default. Control frames carry no binary payload.

Headers identify version, message type, transfer id, lease generation, offset,
payload length, and SHA-256 where applicable. The receiver validates all lengths,
offsets, types, overflow, and configured byte limits before allocating/writing.
Only one chunk is in flight per transfer initially; this bounds memory and
provides backpressure. A larger acknowledgement window is a future optimization.

Operations: `open`, `ready`, `chunk`, `ack`, `finish`, `complete`, and `error`.
For uploads, open supplies the sender-known metadata and ready returns receiver
progress. For downloads, open requests a snapshot using its identity and an
authorized source; the helper offers the snapshot metadata in ready, and the
receiver replies ready with its committed offset before any chunk. Bind length
and hash once the snapshot is created, then require exact matches on resume.
Unknown versions or malformed frames fail without changing a completed artifact.
Protocol data is never mixed with job output/replay or diagnostic text.

## Transfer identity and resume

A server-generated transfer id binds the direction, session id, member id,
lease generation, logical artifact, expected length, and complete SHA-256.
The receiver rejects reuse of an id with different metadata. Transfer ids are
opaque safe identifiers, never filesystem paths supplied by a client.

For uploads, the helper exclusively locks a private state directory outside
/workspace, scoped to that transfer and lease generation. It stores partial
bytes and a sidecar recording immutable metadata and committed offset. The
private state belongs to the current lease and is removed on release/reset.
For downloads, the same receiving state lives in GoodFlows' session spool.

On open/reconnect, the receiver returns its committed offset. The sender seeks
to that boundary and continues. Each chunk includes its offset and SHA-256.
The receiver validates the chunk, writes it, synchronizes file data, atomically
updates and synchronizes its committed-offset sidecar, then acknowledges.
On restart, bytes past the recorded offset are truncated before accepting more.
An acknowledged offset cannot exceed verified durable data. A lost ack is safe:
reopen reports the authoritative offset rather than appending duplicate bytes.
Only one writer may own a transfer; uncertain old execs must be stopped or
confirmed fenced before a replacement starts using the existing pool owner rules.

Finish verifies the total length and complete SHA-256, then atomically publishes
the received archive/file on the same filesystem and records completion.
Repeated finish/open after an acknowledgement loss returns the completed result.
A final hash mismatch invalidates the partial transfer and reports an explicit
restart-required error rather than committing corrupted content.

## Receiving workspaces

The server validates its original workspace spool before transferring it. The
helper independently enforces the same compressed/expanded size, entry count,
entry type, path/link confinement, and deadline rules before extraction.
A complete archive is staged and checksum-verified before extraction starts.
No job may execute while hydration is incomplete. A failed extraction quarantines
the member for reset, as the existing pool session contract requires.
Chunk resume covers archive delivery; extraction is not resumed midway.
Completed readiness is recorded with the current lease generation, and retrying
finish must not extract a successfully committed workspace a second time.

The proposed compressed workspace default remains 256 MiB. Expanded-size, entry-count, and
deadline defaults are set in design.md D13 and validated at boot.
Use disk spooling rather than loading the full archive into RAM.

## Sending reports

The helper snapshots an authorized direct regular report file into its private
transfer area, refusing symlinks, special files, and files over the existing
32 MiB report cap. It records the immutable snapshot's length and SHA-256 before
sending. Snapshot creation is bounded and serialized with next-exec admission
and release; detect size/type changes and do not treat mutable source metadata
as immutable. Resume always reads that snapshot, not a newly resolved path.

GoodFlows commits each received chunk to its own spool and acknowledges it.
A subsequent invocation starts sending at that committed offset for the same
snapshot id/hash. Only after complete verification does GoodFlows serve the
HTTP response. Next exec or member release invalidates the transfer and retains
the existing 410 contract. HTTP Range/resumable downloads to goodci are separate
future work. The bounded GOODFLOWS_OUTPUT read remains capped at 65,537 bytes;
it uses the helper's `collect` command, which also returns the report manifest,
without chunk resume for such a small payload.

## Provisioning and cleanup

Build a release binary for each supported Sprite Linux architecture, record its
version and checksum, install it before the golden checkpoint, and verify the
version during provisioning. User setup must not leave an incompatible helper
in the checkpoint. Bootstrap the small binary via the filesystem API only if
its measured size is at most the documented 16 MiB (16,777,216-byte) write limit; oversized binaries fail
provisioning with an explicit error until another bootstrap is provided.

Transfers are bounded by a dedicated node-wide transfer semaphore (default 2,
configured in `GoodFlows.Pools.Config`), separate from the pool member jobs.
Report fetches wait ahead of workspace hydrations for a permit, and one
session hydrates its members one at a time, so a session's copies cannot take
every permit while a client waits on a report. Each report download reserves
the 32 MiB report cap from the node spool budget (and the account's share of
it) before it starts, settled to the actual size once verified. Reconnect
attempts and per-attempt timeouts remain within the existing session deadline.
Release, expiry, and reset terminate helper invocations before member reuse;
private state and snapshots are explicitly removed and the checkpoint restored.
A startup janitor removes spools of earlier boots, and a periodic sweep (every
10 minutes) removes this boot's session spools whose session ended or has no
live local coordinator. No promise is made to preserve resumability across
session or VM lifecycle boundaries.

## Hardening (verification follow-up)

- A watchdog thread ends `receive`/`send` with exit status 3 (stderr
  `idle_timeout`/`deadline`, no error frame) when a stdout write makes no
  progress for the idle timeout, or once the absolute deadline plus 1 s has
  passed. Writes go out in slices of at most 64 KiB, and each completed
  slice counts as progress. The server treats exit 3 as a retryable helper
  failure.
- `collect` lists only report names that `send` accepts
  (`[A-Za-z0-9._-]{1,128}`); other `*.jsonl` names are counted in the
  optional collect header field `reports_skipped` (present only when > 0),
  surfaced to clients as `reports.skipped`, and never offered for download.
- `send --source` opens the exec dir and its `reports/` with
  `openat(O_DIRECTORY|O_NOFOLLOW)` and the file with `O_NOFOLLOW`, so a
  symlinked exec or reports directory is `source_rejected`.
- `package.sh` stages binaries plus manifest and swaps them in atomically
  (`mv --exchange`), so readers never see a manifest that does not match its
  binaries; when the fallback two-rename swap fails, the previous output is
  restored. It reads binaries from cargo's real target directory (`cargo
  metadata`, so `CARGO_TARGET_DIR` is honoured), publishes only the targets
  built in that run, remaps the builder's paths (`--remap-path-prefix`) for
  reproducible output, version-checks cross-architecture binaries through
  `qemu-<arch>` when installed, and records `rustc -V` in the manifest as
  `rustc` (readers ignore it).
- `--idle-timeout-ms` and `--extract-timeout-ms` must be positive; `0` is a
  usage error (exit status 2).
- A `send` that finds the snapshot lock held waits up to its idle timeout
  (default 60 s) before reporting `busy`, like `receive`.
- A sidecar commit reports whether its atomic rename happened; error cleanup
  truncates uncommitted bytes only when the failure came before the rename,
  so the on-disk data never falls behind the offset the sidecar records.
- Members record the helper identity `<version>+p<protocol>`, not the
  binaries' SHA-256: a member is stale only when its helper is older than the
  server's (design.md D2), so rebuilds and rolling deploys do not churn
  members. The installed binary's SHA-256 is still verified against the
  manifest during provisioning.
- Server side: every attempt and the helper's `--deadline-unix-ms` are bound
  to the session's real expiry (creation plus max lifetime); no attempt or
  retry starts after it, and no workspace attempt starts unless the member is
  still leased to the session under the transfer's lease generation. The first frame of an attempt may take
  `helper_idle_timeout_ms` plus the ack timeout (a replacement helper may
  wait that long for the previous invocation's lock); `busy` is retried with
  backoff. Each attempt ends with a synchronous stdin EOF and a bounded wait
  for the helper to exit before the stream is stopped. Every frame must
  carry the attempt's `transfer_id`; spooled download progress bound to
  another length or hash fails with `metadata_mismatch` and is discarded.
  Helper stdout per attempt is budgeted (control frames, or the 32 MiB
  report plus framing) and stderr forwarding is capped at 64 KiB.
- The helper's workspace validation and extraction budget is its own setting,
  `helper_extract_timeout_ms` (default 300 s), separate from the server's
  60 s archive preflight.

## Verification and integration work

First spike the real exec transport with a binary transfer larger than 16 MiB,
separate stdout/stderr, stdin EOF, forced disconnect, and a new invocation that
resumes from the last committed chunk. Verify checksums and bounded memory.
No assumption of unlimited WebSocket transfer size substitutes for this spike.
**Status: pending.** The script is `sprite-transfer/examples/transport-spike.exs`;
no Sprites credential was available, so it has not run (design.md D12).

Rust tests cover fragmented framing, arbitrary binary bytes, malformed lengths,
chunk/hash/identity mismatches, disconnect before/after acknowledgement, crash
between data and sidecar synchronization, competing writers, idempotent finish,
path/link escapes, disk-full errors, and cleanup. Test download resume against
the same snapshot and invalidation on release/next exec. Server integration tests
cover lease fencing, helper version mismatch, deadlines, and member readiness.

The integrated contract is in specs/sprite-transfers/spec.md. The implementation
plan is implementation-plan.md and tasks.md tracks the whole pool change. Keep
the companion goodci change separate.
