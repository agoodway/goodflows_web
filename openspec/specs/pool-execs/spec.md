# pool-execs Specification

## Purpose

Defines the WebSocket channel contract a client uses to run commands on its leased pool members, stream their output, survive reconnects, and collect each command's outputs file and test reports.

## Requirements

### Requirement: Socket authentication
The server SHALL serve a Phoenix Channels v2 WebSocket at `/api/v1/socket`. A connection MUST present a private (`sk_`) API key through the Phoenix socket auth token. A connection without one, with a `pk_` key, or with an unknown, revoked, or expired key MUST be refused. A key passed in the URL query string MUST be refused and MUST NOT be logged.

#### Scenario: Valid private key
- **WHEN** a client connects with a valid `sk_` key as its auth token
- **THEN** the connection is accepted

#### Scenario: Key in the query string
- **WHEN** a client connects to `/api/v1/socket/websocket?token=sk_...`
- **THEN** the connection is refused and no log line contains the key

### Requirement: Joining a session channel
A client SHALL join topic `pool_session:<session_id>`. The join MUST be refused for a session of another account (`not_found`), a session created by another key (`forbidden`), or an ended session (`ended`, with its end reason). A successful join reply MUST contain the session status, its granted members with their readiness, and every exec of the session that is still running.

#### Scenario: Join an active session
- **WHEN** the creating key joins `pool_session:<id>` for an active session with one ready member
- **THEN** the join reply lists that member as ready and no running execs

#### Scenario: Join an expired session
- **WHEN** a client joins a session that expired
- **THEN** the join is refused with `ended` and the end reason

### Requirement: Session events
The server MUST push `member_granted`, `member_ready`, `member_lost`, and `session_ended` events on the session topic as those changes happen. Each member event MUST carry the member id and name. `session_ended` MUST carry the final status and reason.

#### Scenario: Member becomes ready
- **WHEN** the workspace is extracted into a newly granted member
- **THEN** the channel receives `member_granted` for it, then `member_ready`

### Requirement: Start an exec
A client SHALL start an exec by calling `exec` with `member_id`, either `command` (a string run with `sh -c`) or `argv` (a non-empty list run directly), an optional `cwd` relative to `/workspace`, optional `env` (string to string), optional `timeout_ms`, optional `collect_reports`, and optional `job` and `step` labels. The reply MUST be `{exec_id}`, and it MUST reach the client before any `output` or `exit` of that exec. Setting both or neither of `command` and `argv` MUST be rejected. `cwd` MUST be checked lexically (no absolute path, no `..` segment, no NUL byte); a symlink inside the workspace is followed like any other path. `env` names MUST match `[A-Za-z_][A-Za-z0-9_]*` with string values, `collect_reports` MUST be a boolean, and `job` and `step` MUST be strings of at most 255 bytes. A request MUST be rejected with `invalid_request` when `argv` has more than 4,096 items, `env` has more than 1,024 entries, or `command` (or all `argv` items) plus every env name and value exceed 262,144 bytes in total. The socket MUST refuse WebSocket frames over 1 MiB.

#### Scenario: Shell command
- **WHEN** a client calls `exec` with `{"member_id": "...", "command": "cargo test --locked", "cwd": ".", "job": "test"}`
- **THEN** the reply carries an `exec_id` and the command starts in `/workspace` with `sh -c`

#### Scenario: Output before the reply is processed
- **WHEN** the command writes output before the server has replied to `exec`
- **THEN** the client receives the `exec` reply first, then the `output`

#### Scenario: Oversized request
- **WHEN** a client calls `exec` with an `env` of 2,000 entries
- **THEN** the call is rejected with `invalid_request` naming `env` and nothing runs

#### Scenario: Both forms given
- **WHEN** a client calls `exec` with both `command` and `argv`
- **THEN** the call is rejected with error `invalid_request` naming both fields

### Requirement: Exec preconditions
An exec MUST be rejected when its member is not granted to this session (`not_granted`), is not ready (`member_not_ready`), or already has a running exec (`member_busy`). It MUST also be rejected when `cwd` is absolute, contains a `..` segment, or escapes `/workspace` (`invalid_request`). A rejected exec MUST NOT run anything.

#### Scenario: Member busy
- **WHEN** a client starts a second exec on a member whose first exec is still running
- **THEN** the call is rejected with `member_busy`

### Requirement: Exec environment
An exec SHALL run with the member's default environment plus the request `env`. The server MUST set `GOODFLOWS_OUTPUT` to a fresh, empty file path inside the member for every exec. With `collect_reports` true it MUST also set `GOODFLOWS_REPORT_DIR` to a fresh, empty directory. Request values for those two names MUST be ignored. Stdin MUST be closed.

#### Scenario: Client tries to set the output path
- **WHEN** a client sends `env` containing `GOODFLOWS_OUTPUT=/tmp/x`
- **THEN** the command sees a server-chosen `GOODFLOWS_OUTPUT` instead

### Requirement: Exec env and commands are not stored
The server MUST NOT persist or log an exec's `env` values, `command`, or `argv`. Exec records MAY keep ids, labels, status, exit code, timings, byte counts, and the bounded final exit payload (outputs bytes, truncation flags, report manifest, duration, and error reason) required for replay. Streaming stdout and stderr MUST NOT be persisted. User code may deliberately write secrets into outputs or report names; the server MUST NOT copy request secrets into metadata, diagnostics, or logs.

#### Scenario: Secret in env
- **WHEN** an exec is started with `env` containing a secret token and the command does not write it to outputs or report names
- **THEN** no database row or log line contains that value

### Requirement: Output streaming
While an exec runs, the server MUST push `output` events carrying `exec_id`, a per-exec `seq` starting at 0 and increasing by 1, `stream` (`stdout` or `stderr`), and `data` as base64-encoded bytes. Sequence numbers MUST reflect SDK arrival order; cross-stream process write order cannot be inferred. Bytes MUST be delivered in order within each stream, and non-UTF-8 output MUST be preserved.

#### Scenario: Interleaved streams
- **WHEN** the SDK delivers stdout, then stderr, then stdout chunks
- **THEN** the client receives `output` events with consecutive `seq` values whose `stream` fields follow that order

### Requirement: Execs survive reconnects
An exec MUST keep running when the client's socket or channel drops, until the session ends. On rejoin, a client SHALL send `resume` with each exec id and its last received `seq`; `last_seq` -1 MUST be accepted when no output has been received. The server MUST replay buffered output after that `seq`, ordering replay before newer live events. When output was evicted from the per-exec buffer, it MUST push a `gap` event (`exec_id`, `from_seq`, `to_seq`) with the missing range before the replay. After the in-memory buffer is gone, the persisted final output seq MUST allow a gap covering all missing output before the persisted exit. Outside a resume, live output that skips seqs the client was never sent MUST be preceded by a `gap`, and so MUST an `exit` whose final output seq is past the last seq sent; no `output` MAY follow an exec's `exit`, and resuming an exec already resumed on the same channel MUST NOT push its `exit` again. Running execs listed in the join reply MUST get their `exit` before `session_ended` even when the client never resumed them. A `resume` with more than 1,000 entries MUST be rejected with `invalid_request`; malformed entries and execs of other sessions MUST be ignored. Replay and cancel MUST be served by the exec's own server, so a busy session coordinator never delays them.

#### Scenario: Short drop
- **WHEN** a client reconnects within the session grace and resumes an exec from seq 41
- **THEN** it receives every `output` event from seq 42 onward with no gap

#### Scenario: Buffer overflow during a drop
- **WHEN** an exec produced more output than the per-exec buffer while the client was disconnected
- **THEN** on resume the client receives a `gap` event naming the evicted range, then the retained output

#### Scenario: Live output skips ahead
- **WHEN** the channel last sent seq 0 of an exec and the next live output it receives is seq 3
- **THEN** it pushes a `gap` for 1 through 2, then the output

#### Scenario: Resume after exec owner stops
- **WHEN** an ended exec has final output seq 50, its buffer is gone, and the client resumes from seq 41
- **THEN** the server sends a gap covering 42 through 50 before replaying the persisted exit

### Requirement: Exec exit event
When an exec ends, the server MUST push `exit` with `exec_id`, `status` (`exited`, `timed_out`, `cancelled`, or `error`), `exit_code` (null unless `exited`), `duration_ms`, `error_reason` (null unless `status` is `error`, e.g. `owner_lost`), the base64 contents of the `GOODFLOWS_OUTPUT` file (null when empty or missing), whether that content was truncated, and, when reports were collected, the report manifest, and `collect_failed` (true when reading the outputs file and manifest after the end failed, in which case both are missing). Outputs and reports MUST be read after every end, including `timed_out`, `cancelled`, and `error`, once the command is confirmed stopped. `exit` MUST follow the exec's last `output` event and MUST be replayable through `resume`.

#### Scenario: Command writes outputs
- **WHEN** a command writes `{"changed":true}` to `$GOODFLOWS_OUTPUT` and exits 0
- **THEN** `exit` has status `exited`, exit code 0, and `outputs` decoding to `{"changed":true}`

#### Scenario: Exec owner lost
- **WHEN** the node running an exec is confirmed lost
- **THEN** `exit` has status `error` and `error_reason` `owner_lost`

#### Scenario: Session coordinator stops
- **WHEN** the session's coordinator stops while an exec runs
- **THEN** the command is killed and the exec ends `error` with `error_reason` `owner_lost`

#### Scenario: Outputs unreadable after the end
- **WHEN** the outputs file and manifest cannot be read after an exec ends
- **THEN** `exit` has `collect_failed` true and null `outputs` and `reports` instead of reporting empty outputs or an empty manifest

### Requirement: Outputs file is bounded
The server MUST read at most 65,537 bytes of the outputs file and MUST set the truncated flag when the file is larger. It MUST NOT parse or validate the contents. That remains the client's job.

#### Scenario: Oversized outputs file
- **WHEN** a command writes 100 KiB to `$GOODFLOWS_OUTPUT`
- **THEN** `exit` carries the first 65,537 bytes with `outputs_truncated` true

### Requirement: Exec timeout
Each exec MUST be bounded by `min(timeout_ms, server exec maximum)`, or by the server maximum when `timeout_ms` is omitted, measured as elapsed time regardless of output. An exec that exceeds it MUST be killed and end with status `timed_out`. A `timeout_ms` below 1 MUST be rejected.

#### Scenario: Job runs too long
- **WHEN** an exec started with `timeout_ms` 5000 runs for 6 seconds
- **THEN** it is killed and `exit` has status `timed_out`

### Requirement: Cancel an exec
A client SHALL call `cancel` with an `exec_id` of its session; an exec of another session or account MUST be refused with `not_found` and keep running. The server MUST kill the running command and end the exec with status `cancelled`. Cancelling an ended exec MUST succeed without effect. After a cancel or timeout the server MUST kill the command's whole process group in the member and confirm it is gone before the exit is persisted; when that cannot be confirmed, the member MUST be reset (announced as `member_lost`) instead of taking another exec.

#### Scenario: Ctrl-C locally
- **WHEN** a client cancels a running exec
- **THEN** the command is killed and `exit` has status `cancelled`

#### Scenario: Remote process survives the kill
- **WHEN** the command's process group cannot be confirmed gone after a cancel
- **THEN** the exit is still pushed and the member is reset and replaced

### Requirement: Report manifest
With `collect_reports` true, the exit manifest MUST list each direct regular `*.jsonl` file in `GOODFLOWS_REPORT_DIR`, with name and byte size, in name order. It MUST skip subdirectories, symlinks, and other file types, and list at most a server-configured number of files, flagging truncation. Files larger than 32 MiB MUST be listed with `too_large` true. Only names made of `A-Z`, `a-z`, `0-9`, `.`, `_`, and `-` (at most 128 bytes) MUST be listed; other `*.jsonl` files MUST be counted as `skipped` instead.

#### Scenario: Two reports and a symlink
- **WHEN** a command leaves `a.jsonl`, `b.jsonl`, and a symlink `c.jsonl` in the report dir
- **THEN** the manifest lists `a.jsonl` and `b.jsonl` only

#### Scenario: Undownloadable report name
- **WHEN** a command leaves `my report.jsonl` in the report dir
- **THEN** it is not listed, and the manifest counts it in `skipped`

### Requirement: Report download
`GET /api/v1/pool-execs/:id/reports/:name` SHALL return a listed report file's bytes (`application/x-ndjson`) to the session's creating key. It MUST revalidate file type, confinement, and size at download time, enforce the 32 MiB cap while snapshotting and transferring to a disk spool in bounded chunks, and serialize with release and next-exec admission. Internal Sprite-to-GoodFlows report transfers MUST resume from acknowledged chunks against an immutable snapshot and complete integrity verification before serving HTTP; client HTTP Range resume is outside this contract. Report transfers MUST run on the session coordinator, and a request on another node MUST receive the verified bytes through bounded owner RPC. Concurrent requests for the same report MUST share one internal transfer. Before a report transfer starts, the 32 MiB report cap MUST be reserved from the node spool budget and the account's share of it, and settled to the report's actual size once verified; the reservation MUST be released when the report is invalidated or the session ends. Report transfers MUST take precedence over queued workspace hydrations for transfer capacity. When the verified report is not available within the configured fetch wait, the transfer capacity or spool budget is exhausted, or the internal transfer fails (including its worker dying), the API MUST respond `503` with `Retry-After` while the report remains eligible. The endpoint MUST accept `Accept: application/x-ndjson`. It MUST respond `404` for an unlisted, no-longer-regular, oversized, or `too_large` name, and `410` once the member has started another exec or been released, including when that happened while the internal transfer was running. A `200` MUST carry the file's SHA-256 in `x-content-sha256`, and a response whose body cannot be completed after its headers were sent MUST end with a dropped connection, never a clean short body.

#### Scenario: Download before the next exec
- **WHEN** a client downloads `a.jsonl` from an exec whose member is still granted to the session and has not started another exec
- **THEN** the API responds `200` with the file bytes

#### Scenario: Download after the next exec started
- **WHEN** the same member has started another exec
- **THEN** the API responds `410`

#### Scenario: Report invalidated mid-stream
- **WHEN** a report is invalidated while another server node streams it to the client
- **THEN** the connection is dropped before the body completes

#### Scenario: Internal report transfer not ready in time
- **WHEN** the internal Sprite-to-GoodFlows transfer of an eligible report has not completed within the fetch wait
- **THEN** the API responds `503` with `Retry-After`, and a retry reuses the transfer progress

### Requirement: Session end stops execs
When a session ends for any reason, every running exec of the session MUST be killed and pushed `exit` to any joined client before `session_ended`: with status `error` and `error_reason` `owner_lost` when the session ended with `session_owner_lost`, otherwise with status `cancelled`.

#### Scenario: Session released with a running exec
- **WHEN** a client releases its session while an exec is running
- **THEN** the exec ends `cancelled` and the channel receives its `exit` before `session_ended`

