# gf-transfer

`gf-transfer` is a small, statically linked helper that runs inside each GoodFlows Sprite pool member. It moves bytes between GoodFlows and the Sprite over a non-TTY exec session. stdin and stdout carry only binary protocol frames, and stderr carries short diagnostics. It never opens a listening port and never needs a Sprites credential. Each invocation handles one transfer and then exits.

| Command   | Direction                  | Purpose                                                                 |
|-----------|----------------------------|-------------------------------------------------------------------------|
| `receive` | GoodFlows → Sprite         | Resumable workspace archive upload, verified publish, confined extract |
| `send`    | Sprite → GoodFlows         | Resumable report download from an immutable private snapshot           |
| `collect` | Sprite → GoodFlows         | One bounded frame: exec outputs (≤ 65,537 B) and the report manifest   |
| `cleanup` | —                          | Delete the private state dir (all partials and snapshots)              |
| `version` | —                          | Version handshake                                                      |

The normative design lives in `openspec/changes/add-sprite-pools/` (`transfer-design.md`, `specs/sprite-transfers/spec.md`, design.md D8/D12/D13).

## Protocol v1

### Framing

```text
+----------------------+---------------------------+------------------------+
| u32 big-endian H     | H bytes UTF-8 JSON object | len raw payload bytes  |
+----------------------+---------------------------+------------------------+
```

- `H` must be within `1..=8192`. A value of 0 is rejected (`protocol`), and a value above 8192 is rejected (`too_large`) before any header byte is read or allocated.
- `len` is the header's integer field `"len"`. If the field is absent, `len` is 0. Only `chunk` and `collect` may carry a payload, and a nonzero `len` on any other type is a `protocol` error. A `len` above the negotiated `max_payload` (default and ceiling 1,048,576) is rejected (`too_large`) before the payload is read or allocated.
- Every header carries `"v":1`. Any other value, including `"1"`, `1.0` or `null`, gives `unsupported_version`. A missing `v` is a `protocol` error.
- Unknown keys are ignored. Decoders never depend on key order and handle arbitrary fragmentation.
- Integers (offsets, lengths, `lease_generation`, sizes) are JSON non-negative integers that fit in a u64. Negative, fractional, string or out-of-range values are `protocol` errors. A chunk where `offset + len` overflows u64 is `bad_offset`.
- `sha256` values are 64 lowercase hex characters.
- `transfer_id`, `session_id`, `member_id` and `artifact` must match `^[A-Za-z0-9._-]{1,128}$` and must not be `.` or `..`. A transfer id is only ever used as a single path component under the server-supplied state dir.

### Deterministic encoding (key order)

Encoders write compact JSON (no whitespace) in this fixed key order: `"v"`, `"type"`, `"transfer_id"` (if the type has one), then the type's fields in the order below, with `"len"` last. Optional fields are omitted when unused. The Elixir encoder produces the same bytes, and `tests/fixtures/*.bin` pin them.

| type       | key order after `v`, `type`                                                                                                   |
|------------|-------------------------------------------------------------------------------------------------------------------------------|
| `open`     | `transfer_id, direction, session_id, member_id, lease_generation, artifact, max_payload[, length, sha256]` (length/sha256: upload only) |
| `ready`    | `transfer_id[, committed_offset][, length, sha256], max_payload[, completed]`                                                 |
| `chunk`    | `transfer_id, offset, sha256, len`                                                                                            |
| `ack`      | `transfer_id, committed_offset`                                                                                               |
| `finish`   | `transfer_id, length, sha256`                                                                                                 |
| `complete` | `transfer_id, length, sha256[, extracted]`                                                                                    |
| `error`    | `code, message`                                                                                                               |
| `collect`  | `outputs_present, outputs_truncated, reports, reports_truncated, [reports_skipped], len` (each report: `name, size, too_large`; `reports_skipped` only when > 0) |

`len` is always written for `chunk` and `collect`, even when it is 0, and is never written for control frames.

`ready` takes three shapes:

- Upload reply: `committed_offset, max_payload, completed`.
- Download offer from the helper: `length, sha256, max_payload`.
- Download progress from the receiver: `committed_offset, max_payload`.

### Conversations

There is one chunk in flight at a time. The sender waits for the matching `ack` before it reads or sends the next chunk.

**Upload (`receive`; GoodFlows is the sender):**

```text
server → open{direction:"upload", length, sha256, max_payload:P}
helper → ready{committed_offset:C, max_payload:min(P, own), completed:false|true}
server → chunk{offset:C, sha256, len} + bytes      helper → ack{committed_offset}
...                                                 (repeat)
server → finish{length, sha256}
helper → complete{length, sha256, extracted:true}   (after verify, publish and extract)
```

If `completed:true`, the workspace was already extracted for this transfer. The server just sends `finish` and gets `complete` again, and nothing is re-extracted.

**Download (`send`; the helper is the sender):**

```text
server → open{direction:"download", artifact:<basename of --source>, max_payload:P}
helper → ready{length, sha256, max_payload:min(P, own)}    (snapshot offer)
server → ready{committed_offset:C, max_payload:P2}
helper → chunk{offset:C, ...} + bytes                     server → ack{committed_offset}
...
helper → finish{length, sha256}
server → complete{length, sha256}
```

The helper's chunk size is `min(negotiated, P2)`.

The receiver sends an `ack` only after all of the following have happened, in order: the chunk's SHA-256 is verified, its offset equals the expected next offset, the data is fsync'd, and the sidecar is atomically replaced (write temp, fsync, rename, fsync dir).

### Error codes

`error{code, message}` messages never contain payload bytes. After a `receive` or `send` has read its first frame, a failure writes one error frame (unless the peer is gone or itself sent `error`) and exits 1.

| code                  | meaning                                                                                   |
|-----------------------|-------------------------------------------------------------------------------------------|
| `unsupported_version` | `v` ≠ 1                                                                                   |
| `protocol`            | malformed/unexpected frame, bad identifier, wrong direction, stdin closed mid-transfer   |
| `too_large`           | header > 8192, payload > negotiated max, artifact > `--max-bytes`                         |
| `bad_offset`          | chunk not at the expected offset, beyond `length`, overflow, or finish before all bytes   |
| `bad_chunk`           | chunk SHA-256 mismatch (the offset does not advance)                                      |
| `metadata_mismatch`   | the transfer id was reused with different identity/length/hash; finish metadata ≠ open    |
| `busy`                | another invocation owns the transfer lock (after waiting up to the idle timeout)          |
| `restart_required`    | whole-file SHA-256 mismatch or damaged state; the partial state was deleted               |
| `archive_rejected`    | archive path/type/link policy violation or a malformed archive                            |
| `archive_too_large`   | expanded bytes or entry count above the limits                                           |
| `disk_full`           | ENOSPC/EDQUOT while receiving or extracting                                               |
| `extract_failed`      | extraction I/O failure, or extraction previously failed or was interrupted (quarantine)   |
| `source_rejected`     | report source is a symlink, special file or missing, changed during the snapshot, or `artifact` ≠ source basename |
| `deadline`            | `--deadline-unix-ms` reached, or the archive extract timeout was exceeded                 |
| `idle_timeout`        | no complete frame within `--idle-timeout-ms`                                              |
| `internal`            | other I/O failures                                                                        |

### Fixtures (`tests/fixtures/*.bin`)

All fixtures use `sha256("\x00\xff\x10\x80abc") = 584319cd…4ff43d`. The test `fixtures_roundtrip` asserts that the encoder reproduces these bytes exactly and that the decoder reads them back. To regenerate them deliberately, run `GF_UPDATE_FIXTURES=1 cargo test --test protocol fixtures_roundtrip`.

| file | bytes | prefix (hex) | header (UTF-8) | payload (hex) |
|------|------:|--------------|----------------|---------------|
| `open_upload.bin` | 266 | `00 00 01 06` | `{"v":1,"type":"open","transfer_id":"t-0001","direction":"upload","session_id":"s-1","member_id":"m-1","lease_generation":3,"artifact":"workspace.tar.gz","max_payload":1048576,"length":7,"sha256":"584319cda5e22523b9f570ba8d262db5b82a75a48c3dd7c70914282ede4ff43d"}` | — |
| `open_download.bin` | 172 | `00 00 00 a8` | `{"v":1,"type":"open","transfer_id":"t-0002","direction":"download","session_id":"s-1","member_id":"m-1","lease_generation":3,"artifact":"a.jsonl","max_payload":1048576}` | — |
| `ready_upload.bin` | 110 | `00 00 00 6a` | `{"v":1,"type":"ready","transfer_id":"t-0001","committed_offset":0,"max_payload":1048576,"completed":false}` | — |
| `ready_offer.bin` | 158 | `00 00 00 9a` | `{"v":1,"type":"ready","transfer_id":"t-0002","length":7,"sha256":"584319cda5e22523b9f570ba8d262db5b82a75a48c3dd7c70914282ede4ff43d","max_payload":1048576}` | — |
| `ready_resume.bin` | 92 | `00 00 00 58` | `{"v":1,"type":"ready","transfer_id":"t-0002","committed_offset":0,"max_payload":1048576}` | — |
| `chunk_binary.bin` | 151 | `00 00 00 8c` | `{"v":1,"type":"chunk","transfer_id":"t-0001","offset":0,"sha256":"584319cda5e22523b9f570ba8d262db5b82a75a48c3dd7c70914282ede4ff43d","len":7}` | `00 ff 10 80 61 62 63` |
| `ack.bin` | 68 | `00 00 00 40` | `{"v":1,"type":"ack","transfer_id":"t-0001","committed_offset":7}` | — |
| `finish.bin` | 137 | `00 00 00 85` | `{"v":1,"type":"finish","transfer_id":"t-0001","length":7,"sha256":"584319cda5e22523b9f570ba8d262db5b82a75a48c3dd7c70914282ede4ff43d"}` | — |
| `complete.bin` | 156 | `00 00 00 98` | `{"v":1,"type":"complete","transfer_id":"t-0001","length":7,"sha256":"584319cda5e22523b9f570ba8d262db5b82a75a48c3dd7c70914282ede4ff43d","extracted":true}` | — |
| `error.bin` | 79 | `00 00 00 4b` | `{"v":1,"type":"error","code":"bad_chunk","message":"chunk sha256 mismatch"}` | — |
| `collect.bin` | 174 | `00 00 00 a7` | `{"v":1,"type":"collect","outputs_present":true,"outputs_truncated":false,"reports":[{"name":"a.jsonl","size":123,"too_large":false}],"reports_truncated":false,"len":3}` | `6f 6b 0a` (`"ok\n"`) |

## CLI

GoodFlows supplies every path and limit as argv. Unknown or duplicate flags are a usage error: exit 2 with no output on stdout.

```sh
gf-transfer version
# {"name":"gf-transfer","version":"0.1.0","protocol":1}

gf-transfer receive --state-dir /var/lib/gf-transfer/state --dest /workspace \
  --max-bytes 268435456 --max-expanded-bytes 2147483648 --max-entries 100000 \
  --extract-timeout-ms 300000 --idle-timeout-ms 60000 --deadline-unix-ms 1793577600000 \
  [--max-payload 1048576]

gf-transfer send --state-dir /var/lib/gf-transfer/state --source /tmp/gf-exec-42/reports/a.jsonl \
  --max-bytes 33554432 --idle-timeout-ms 60000 --deadline-unix-ms 1793577600000 \
  [--max-payload 1048576]

gf-transfer collect --outputs /tmp/gf-exec-42/outputs [--report-dir /tmp/gf-exec-42/reports] \
  [--max-outputs 65537] [--max-reports 100] [--max-report-bytes 33554432]

gf-transfer cleanup --state-dir /var/lib/gf-transfer/state
```

- **`receive`** answers an `upload` open. If `length > --max-bytes` it fails with `too_large`. Otherwise it resumes or creates `STATE/<transfer_id>/`, receives chunks, and on `finish` rehashes the whole part file with bounded reads. It then atomically publishes the archive (same filesystem), validates it, and extracts it into `--dest`. Only after that does it reply `complete{extracted:true}`.
- **`send`** answers a `download` open whose `artifact` equals `basename(--source)`. It reuses a matching snapshot, or creates one: it opens the source with `O_NOFOLLOW|O_NONBLOCK`, and walks the two directories directly above it (the exec dir and its `reports/`) with `openat(O_DIRECTORY|O_NOFOLLOW)`, so a symlinked `reports/` or exec dir is refused with `source_rejected` (the ancestors above those, such as `/tmp`, are server-owned and opened normally). It requires a regular file of at most `--max-bytes` bytes, and copies it while hashing. It refuses the source if the size, mtime or inode changed during the copy. It then offers length and hash and serves chunks from the receiver's committed offset.
- **`collect`** writes one frame and exits 0.
  - Outputs: if the outputs path is a symlink, a non-regular file, or missing, `outputs_present` is false and `len` is 0. Otherwise the payload holds at most `--max-outputs` bytes, and `outputs_truncated` is set when the file is longer.
  - Reports: only direct children of the report dir are listed, and only regular files (checked with `lstat`) whose names end in `.jsonl`. A name that `send` could never serve (anything but `[A-Za-z0-9._-]{1,128}`, such as `my report.jsonl`, or a non-UTF-8 name) is left out and counted in `reports_skipped`, which is present in the header only when it is above 0, so every listed report can be downloaded. They are sorted by name and capped at `--max-reports`; extra entries set `reports_truncated`. `too_large` is set when a file's size is above `--max-report-bytes`. A missing report dir (or one that is not a directory) gives an empty list. If the list would push the header past 8192 bytes, trailing entries are dropped and `reports_truncated` is set.
- **`cleanup`** removes the whole state dir and exits 0. A missing dir is not an error.

Exit codes: 0 on success, 1 on error (after an `error` frame once the protocol had started), 2 on usage errors, and 3 when the stdout watchdog ends a `receive`/`send` (see **Termination**; no `error` frame, a one-line `idle_timeout`/`deadline` diagnostic on stderr).

## Archive policy (`receive`)

The archive is fully received, hash-verified and published before validation starts. Validation reads all of the metadata first and writes nothing. It rejects:

- absolute paths and any `..` component;
- device, FIFO, socket and other special entries;
- duplicate non-directory paths, which includes swapping a directory for a link;
- entries beneath an archive symlink or file;
- hardlinks whose target is not an earlier regular file reached only through directories;
- symlinks with an absolute target, or whose target escapes the destination when resolved through the final set of archive symlinks (this catches chains and links created later in the archive).

It also enforces `--max-expanded-bytes`, `--max-entries` and `--extract-timeout-ms` (one wall-clock budget for validation and extraction). GNU long names are capped at 4 KiB and pax headers at 64 KiB. A pax `size` that disagrees with the header size is rejected.

Extraction uses `openat`, `mkdirat`, `symlinkat` and `linkat` relative to a descriptor for `--dest`, and opens every parent with `O_NOFOLLOW`, so preexisting symlinks in the destination are never followed:

- A parent component that is a symlink fails with `extract_failed`.
- A file or link entry replaces an existing non-directory at the same path (the old link itself is removed, never its target).

A `.tar.gz` inside the archive is just a regular file. The destination is `syncfs`'d before completion is recorded. Plain (uncompressed) tar is accepted as well as gzip.

## Lifecycle and state

**State dir.** `--state-dir` is a private, server-chosen directory outside `/workspace`, created with mode 0700. Each transfer gets its own subdirectory, `STATE/<transfer_id>/`:

| file                    | owner     | content                                                                            |
|-------------------------|-----------|------------------------------------------------------------------------------------|
| `lock`                  | both      | `flock(LOCK_EX)` for the invocation's lifetime (released on process exit)          |
| `state.json`            | `receive` | immutable meta + `committed_offset` + `state` (`receiving`/`published`/`extracting`/`extracted`/`extract_failed`) |
| `data.part`             | `receive` | partial bytes                                                                      |
| `artifact`              | `receive` | verified published archive                                                         |
| `snapshot`, `snapshot.json` | `send` | immutable private copy and its bound `{key, length, sha256}`                       |

**Ownership.** An invocation that finds the lock held retries for up to `--idle-timeout-ms` (bounded by the deadline) and then fails with `busy`, without touching the other invocation's state. Because the lock is an OS advisory lock, it disappears when the process dies.

**Termination.** A helper exits on stdin EOF, after `--idle-timeout-ms` with no complete frame (`idle_timeout`), and at `--deadline-unix-ms` (`deadline`). A stale helper whose exec connection dropped without EOF therefore releases its lock after the idle timeout. A replacement then resumes from the committed offset.

Those checks run while the helper waits for input. A watchdog thread also covers the helper while it is blocked *writing* stdout (for example a 1 MiB chunk into a pipe nobody drains): if a stdout write makes no progress for `--idle-timeout-ms`, or once `--deadline-unix-ms` plus a 1 s grace has passed (whatever the helper is doing, including extraction or snapshotting), the process exits with status 3. Writes are passed to stdout in slices of at most 64 KiB and each completed slice counts as progress, so a slow but steady reader never trips it. The grace lets the cooperative deadline check answer with a `deadline` error frame first.

**Identity.** A transfer id binds the direction, session, member, lease generation, artifact, length and SHA-256. For downloads, length and SHA-256 are bound when the snapshot is created. Reopening an id with any difference fails with `metadata_mismatch` and modifies nothing. A new lease generation must use a new transfer id. State from an old lease can never be resumed into a new one.

**When state becomes invalid.** Member release or reset, session expiry, and (for reports) the next exec all invalidate transfer state. GoodFlows stops or fences helper invocations first, then runs `gf-transfer cleanup --state-dir …` and restores the checkpoint before the member is reused. After cleanup, a reopen starts from offset 0, and a send re-snapshots the current source. Resume never spans a session, a member reset, or a lease generation change.

## Crash semantics

| crash point                                          | on reopen                                                                     |
|------------------------------------------------------|-------------------------------------------------------------------------------|
| before/after chunk data write, before fsync          | sidecar has the old offset; `data.part` is truncated to it; sender resends   |
| after data fsync, before sidecar replace             | same as above (`state.json.tmp` is ignored and replaced)                      |
| after sidecar replace, before ack (lost ack)         | `ready` reports the advanced offset; a stale resend gets `bad_offset`         |
| finish: whole-file hash mismatch                     | `restart_required`; part, artifact and sidecar are deleted; reopen starts at 0 |
| after publish rename, before sidecar `published`     | the artifact is rehashed; if it matches, the transfer is treated as published, otherwise `restart_required` |
| after `published`, before extraction started         | `ready{completed:false, committed_offset:length}`; `finish` extracts          |
| during extraction (`extracting`) or after a failure  | `extract_failed`; GoodFlows quarantines and resets the member (never re-extracts) |
| after `extracted`, before `complete` reached server  | `ready{completed:true}`; `finish` returns `complete` without re-extracting    |
| send: snapshot copied, before `snapshot.json` exists | the stray snapshot is discarded and the source re-snapshotted                 |

The library exposes `FailPoints` hooks (`gf_transfer::FailPoint`) so tests can inject a crash or ENOSPC at each durability boundary without sleeping. Production code passes no hooks.

## Library API (for tests)

- `protocol::{TransferMeta, TransferKey, Limits, Frame, FrameReader, FrameWriter, FrameSource, encode, decode_header}`
- `state::{Receiver, CompletedArtifact, ReceiveState}`: `Receiver::open(root, meta, limits)`, `committed_offset()`, `commit_chunk(offset, data, sha256)`, `finish()`
- `receive::{run_receive, ReceiveConfig}`
- `send::{Snapshot::open_or_create, run_send, serve, SendConfig}`
- `archive::{validate_and_extract, ArchiveLimits}`
- `collect::{collect, run_collect, CollectConfig}`

## Development

From the repository root:

```sh
cargo test --manifest-path sprite-transfer/Cargo.toml
cargo fmt --manifest-path sprite-transfer/Cargo.toml -- --check
cargo clippy --manifest-path sprite-transfer/Cargo.toml --all-targets -- -D warnings
cargo build --release --manifest-path sprite-transfer/Cargo.toml
```

`mix precommit` (and `mix check`) builds the debug binary (`cargo build`)
but does not run the crate's tests, fmt, or clippy, so run these checks
explicitly.

The Elixir suite's `:helper_binary` tests (workspace and report transfers,
hydration, the pools end-to-end test) run this crate's binary locally in
place of a Sprite (`GoodFlows.FakeSprite` looks for `target/debug`, then
`target/release`, then `app/priv/gf-transfer/x86_64-unknown-linux-musl`), and
a config test fails when that binary's `version` handshake no longer matches
`Cargo.toml` (a stale build). A plain `mix test` without the binary skips
those tests with a warning, and fails when `CI` is set (`true` or `1`), so CI
must build the helper first.

## Packaging, release and deploy order

```sh
sprite-transfer/scripts/package.sh                 # → app/priv/gf-transfer/ (gitignored)
GF_TRANSFER_TARGETS=x86_64-unknown-linux-musl sprite-transfer/scripts/package.sh /tmp/out
```

The script builds `--release --locked` static musl binaries for `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`. The release profile uses `opt-level="z"`, LTO, strip, `panic=abort`, and one codegen unit. Cross-architecture targets link with `rust-lld` unless `CARGO_TARGET_<TRIPLE>_LINKER` is set. Run `rustup target add <target>` first.

The script refuses any binary larger than 16,777,216 bytes, which is the filesystem-API bootstrap write limit. It runs the version handshake of every binary: directly when the target architecture matches the host, through `qemu-<arch>` when that is installed, and otherwise it warns and skips it.

Binaries are read from cargo's real target directory (`cargo metadata`), so `CARGO_TARGET_DIR` or a `build.target-dir` setting never leads to packaging a stale binary. Builds remap the crate and cargo-registry paths (`--remap-path-prefix`, appended to any `RUSTFLAGS`), so binaries do not embed the builder's home directory, and two builds with the same toolchain produce the same bytes.

It writes `OUT/<target>/gf-transfer` and `OUT/manifest.json` (only the targets built by this run; earlier per-target directories are dropped). `rustc` records the build's `rustc -V`; GoodFlows ignores it.

```json
{"name":"gf-transfer","version":"0.1.0","protocol":1,"artifacts":[
  {"target":"x86_64-unknown-linux-musl","arch":"x86_64","path":"x86_64-unknown-linux-musl/gf-transfer","sha256":"<hex>","size":705248},
  {"target":"aarch64-unknown-linux-musl","arch":"aarch64","path":"aarch64-unknown-linux-musl/gf-transfer","sha256":"<hex>","size":622256}],
 "rustc":"rustc 1.x.y (...)"}
```

`arch` is the `uname -m` value that provisioning maps to a target. An unmapped value fails provisioning with `unsupported_architecture`. If any target fails, the output directory is left untouched. Publishing is all-or-nothing: the script stages a copy of `OUT` plus the new binaries and manifest in a sibling directory and swaps it in with one atomic `mv --exchange` (coreutils 9.5 or later), so a reader sees either the old binaries with the old manifest or the new ones with the new manifest, never a mix. Without `mv --exchange` it falls back to two renames, and `OUT` is briefly missing (a missing manifest, never a mismatched one); if the second rename fails, the previous `OUT` is restored.

Deploy order:

1. Run `scripts/package.sh` **before** `mix release`, so `app/priv/gf-transfer/` is included in the release. A production release whose manifest is missing or invalid **refuses to boot** while `POOLS_ENABLED` is true (set `POOLS_ENABLED=false` to run without pools); in dev and test such a node only logs an error and disables pools.
2. Deploy the helper artifact together with a compatible GoodFlows server (same protocol version) **before** any goodci rollout that depends on pool sessions.
3. A member records the helper identity `<version>+p<protocol>` it was built with (not the binaries' SHA-256, so rebuilding the same release never makes members stale). A node retires only members whose helper is **older** than its own (lower protocol, or same protocol and lower SemVer version); members built by a newer node are kept, and granted only when this node speaks their protocol. So during a rolling deploy old and new nodes do not retire each other's members back and forth, and bumping `version` in `Cargo.toml` is what rolls the fleet. When provisioning, the installed binary's SHA-256 and version handshake are verified against the manifest before the golden checkpoint is taken.
4. To roll back, redeploy the previous release, which contains its own matching helper artifacts. Members built by the newer release are kept while the protocol matches; with another protocol they are never granted and are replaced as they are released.
