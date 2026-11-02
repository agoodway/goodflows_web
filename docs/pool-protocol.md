# GoodFlows pool protocol

This document is the wire contract between GoodFlows and a pool client such
as `goodci`'s remote executor. It covers the REST calls that start and end a
session, the Phoenix Channels v2 socket that runs commands, and the HTTP
routes for the workspace and test reports. The normative requirements live in
`openspec/changes/add-sprite-pools/specs/` (`pool-sessions`, `pool-execs`);
this page is the client-facing summary. Example payloads marked
`<!-- payload: … -->` are checked by
`app/test/good_flows_web/pool_protocol_doc_test.exs` to have the same keys,
recursively, as the payloads the server really sends (values are
illustrative and not compared), and the documented `exec` request is
checked to be accepted.

## Overview

1. `POST /api/v1/projects/{project}/pools/{pool}/sessions` with a private
   (`sk_`) key starts a session (`waiting`) and returns its channel `topic`.
2. Connect to `wss://<host>/api/v1/socket/websocket?vsn=2.0.0` with the same
   key as the socket auth token and join `pool_session:<id>`.
3. Members arrive as `member_granted`. Upload the working tree once with
   `PUT /api/v1/pool-sessions/{id}/workspace`; each member is announced
   `member_ready` once the workspace is extracted into its `/workspace`.
4. Run commands with `exec`, stream `output`, and collect each `exit` (with
   the `GOODFLOWS_OUTPUT` contents and a report manifest). Download reports
   with `GET /api/v1/pool-execs/{exec_id}/reports/{name}`.
5. `release` (or `DELETE /api/v1/pool-sessions/{id}`) at the end.

Only the API key that created a session may join, upload to, release, or
run commands in it (`forbidden`/`403` for another key of the account,
`not_found`/`404` for another account).

## Socket authentication

The key is sent as the Phoenix socket auth token, in `Sec-WebSocket-Protocol`,
never in the URL:

```text
Sec-WebSocket-Protocol: phoenix, base64url.bearer.phx.<token>
```

`<token>` is the key in **standard** base64 without padding (Phoenix decodes
it with `Base.decode64(padding: false)` despite the `base64url` prefix name;
`phoenix-channel-runtime`'s `ConnectionConfig::auth_token` encodes it this
way). The server selects `phoenix`. The connection is refused (HTTP `403`
before the upgrade) for a missing, unknown, revoked, expired, or public
(`pk_`) key, for any `token` query parameter, while pools are disabled, and
while the node is draining for shutdown.

## Joining

Topic: `pool_session:<session_id>`, join payload `{}`.

Refusals: `{"reason": "not_found"}`, `{"reason": "forbidden"}`, or
`{"reason": "ended", "status": "expired", "end_reason": "client_disconnected"}`.

A successful join replies with the session status, the granted members and
their readiness, and every running exec:

<!-- payload: join -->
```json
{
  "status": "active",
  "members": [{"id": "7c0c…", "name": "gfp-a2b3c4d5e6f7g2h3", "ready": true}],
  "execs": [{"exec_id": "4f1e…", "member_id": "7c0c…", "job": "test", "step": null}]
}
```

While joined, the session's liveness is refreshed on join, every 15 seconds,
and on leave. A session with no joined client for the disconnect grace
(60 seconds by default) expires with `client_disconnected`; running execs are
cancelled and members reset. Rejoin within the grace to keep it.

## Client events (push → reply)

| event | payload | ok reply | error reasons |
|---|---|---|---|
| `exec` | see below | `{"exec_id"}` | `invalid_request` (with `fields`), `not_granted`, `member_not_ready`, `member_busy`, `ended`, `draining`, `unavailable` |
| `cancel` | `{"exec_id"}` | `{}` | `not_found` |
| `resume` | `{"execs": [{"exec_id", "last_seq"}]}` (at most 1,000 entries) | `{}` | `invalid_request` (`fields: ["execs"]`) over 1,000 entries |
| `want` | `{"wanted"}` (0 to the session's `max_members`) | `{}` | `invalid_request` |
| `release_member` | `{"member_id"}` | `{}` | `not_granted`, `unavailable` |
| `release` | `{}` | `{}` | |

Any other event, or one of these without its required keys (for example
`cancel` without a string `exec_id`), replies `invalid_request` with
`fields: []`. `cancel` and `resume` only reach execs of this session: an
exec of another session or account is `not_found` (`cancel`) or ignored
(`resume`). Malformed `resume` entries (a missing or non-string `exec_id`,
a `last_seq` below -1 or not an integer) are ignored. WebSocket frames are
limited to 1 MiB.

`exec` payload:

<!-- payload: exec_request -->
```json
{
  "member_id": "7c0c…",
  "command": "cargo test --locked",
  "cwd": ".",
  "env": {"RUST_LOG": "info"},
  "timeout_ms": 600000,
  "collect_reports": true,
  "job": "test",
  "step": "cargo"
}
```

- Exactly one of `command` (run as `sh -c command`) or `argv` (a non-empty
  list run directly) is required; both or neither is `invalid_request` naming
  both fields.
- `cwd` is relative to `/workspace`; absolute paths and `..` segments are
  `invalid_request`. The check is lexical: a symlink inside the workspace
  that points elsewhere is followed by the member's shell like any other
  path (the member holds nothing but this session's workspace, and it is
  reset before reuse).
- `cwd` defaults to `.`; a `cwd` that is not a string or contains a NUL
  byte is `invalid_request`.
- `env` is an object whose names match `[A-Za-z_][A-Za-z0-9_]*` and whose
  values are strings; its values are added to the member's environment.
  `GOODFLOWS_OUTPUT` (a fresh empty file) and, with `collect_reports`,
  `GOODFLOWS_REPORT_DIR` (a fresh empty directory) are always set by the
  server; request values for them are ignored. Stdin is closed.
- Size limits: `argv` at most 4,096 items, `env` at most 1,024 entries, and
  at most 262,144 bytes in total for `command` (or every `argv` item) plus
  every env name and value. Over a limit is `invalid_request` naming
  `command` or `argv` (and `env` when env is not empty), or `argv`/`env` for
  the item and entry counts.
- `timeout_ms` is optional; the deadline is `min(timeout_ms, server
  maximum)` (1 hour by default) of elapsed time, and the server maximum when
  it is omitted; a `timeout_ms` below 1 or not an integer is
  `invalid_request`.
- `collect_reports` is an optional boolean (default `false`); `job` and
  `step` are optional strings of at most 255 bytes, recorded on the exec.
- One exec at a time per member (`member_busy`). Commands, argv, and env
  values are never stored or logged.

`want` sets the desired total holdings: lowering it never revokes members,
raising it requests more. `release_member` resets one member and lowers
`wanted` to at most the remaining holdings, so it is not replaced
automatically. A running exec on it is cancelled (its `exit` is pushed)
first; `unavailable` means the server running the session could not be
reached, and the member stays held.

The `exec` reply always arrives before that exec's first `output` or `exit`.

## Server events

<!-- payload: member_granted -->
```json
{"member_id": "7c0c…", "name": "gfp-a2b3c4d5e6f7g2h3"}
```

<!-- payload: member_ready -->
```json
{"member_id": "7c0c…", "name": "gfp-a2b3c4d5e6f7g2h3"}
```

`member_lost` means the member could not take the workspace, its exec
owner was lost, or a cancelled or timed-out command could not be confirmed
stopped; it is being reset or replaced and the session keeps its
place in the grant queue:

<!-- payload: member_lost -->
```json
{"member_id": "7c0c…", "name": "gfp-a2b3c4d5e6f7g2h3", "reason": "workspace hydration failed: restart_required"}
```

<!-- payload: output -->
```json
{"exec_id": "4f1e…", "seq": 0, "stream": "stdout", "data": "aGVsbG8K"}
```

`seq` starts at 0 per exec and increases by 1 in the order the server
received chunks from either stream; `data` is base64 (bytes are preserved,
including non-UTF-8).

<!-- payload: gap -->
```json
{"exec_id": "4f1e…", "from_seq": 0, "to_seq": 9}
```

<!-- payload: exit -->
```json
{
  "exec_id": "4f1e…",
  "status": "exited",
  "exit_code": 0,
  "duration_ms": 1830,
  "error_reason": null,
  "outputs": "eyJjaGFuZ2VkIjp0cnVlfQ==",
  "outputs_truncated": false,
  "collect_failed": false,
  "reports": {
    "files": [{"name": "a.jsonl", "size": 123, "too_large": false}],
    "truncated": false,
    "skipped": 0
  }
}
```

- `status` is `exited`, `timed_out`, `cancelled`, or `error`; `exit_code` is
  null unless `exited`; `error_reason` is null unless `error` (for example
  `owner_lost` when the server running the exec was lost).
- `outputs` is the base64 content of `GOODFLOWS_OUTPUT` (at most 65,537
  bytes, `outputs_truncated` when larger; null when empty or missing). The
  server never parses it.
- `reports` is null unless `collect_reports` was set: direct regular
  `*.jsonl` files of `GOODFLOWS_REPORT_DIR` in name order (symlinks,
  subdirectories, and other types skipped), at most 100 by default
  (`truncated`), with `too_large` for files over 32 MiB. Only names made of
  `A-Z a-z 0-9 . _ -` (at most 128 bytes) can be downloaded; other `*.jsonl`
  files are left out and counted in `skipped`.
- Outputs and reports are read after every end, including `timed_out`,
  `cancelled`, and `error`. `collect_failed` is true when that read failed,
  in which case `outputs` and `reports` are both null (nothing was read,
  which is not the same as an empty outputs file or report directory). A
  cancelled or timed out command's process group is killed and confirmed
  gone first.
- `exit` always follows the exec's last `output`.

<!-- payload: session_ended -->
```json
{"status": "expired", "reason": "client_disconnected"}
```

`reason` is null for `released`, otherwise one of `no_member_available`,
`client_disconnected`, `lifetime_exceeded`, `key_revoked`, or
`session_owner_lost`. Every running exec pushes its `exit` before
`session_ended`: `cancelled`, or `error`/`owner_lost` when the session ended
with `session_owner_lost`.

## Resume

Execs keep running while the socket is down (until the session ends). After
rejoining, send `resume` with each exec and the last `seq` you received (`-1`
if none). The server replays buffered output after it, in order, before any
newer live event, and drops duplicates by `seq`:

1. a `gap` (`from_seq`, `to_seq`) for output evicted from the per-exec
   buffer (1 MiB by default), or, once the exec's server has stopped, for all
   output after `last_seq` through the exec's final output seq;
2. the retained `output` events;
3. the `exit`, if the exec has ended (it is persisted, so it can always be
   replayed).

A `gap` means those bytes are lost; the exec itself is unaffected. Gaps
also appear outside a resume: whenever a live `output` skips seqs this
channel never delivered, and before an `exit` whose exec produced output
after the last seq delivered. No `output` follows an exec's `exit`.
Resuming an exec that this channel already tracks is a no-op.

Execs listed in the join reply that you do not `resume` still get their
`exit` before `session_ended`.

## Workspace upload

`PUT /api/v1/pool-sessions/{id}/workspace`, body: a gzip-compressed tar
(`Content-Type: application/gzip`, no `Content-Encoding` other than
`identity`), at most 256 MiB by default, once per session.

| status | meaning |
|---|---|
| `204` | stored and validated; members are hydrated (one at a time per session) and announced `member_ready` |
| `400` | the body could not be read (broken connection or malformed chunked encoding); retry |
| `403`/`404` | another key / another account |
| `408` | body not received within the read deadline (300 s); retry |
| `409` | session ended, workspace already uploaded, or another upload to it in progress |
| `413` | body, expanded size (2 GiB), entry count (100,000), or validation time over the limits; retry with a smaller archive |
| `415` | wrong content type or encoding |
| `422` | corrupt archive, or entries that are absolute, contain `..`, are special files, write through links, or are links resolving outside `/workspace` (names in GNU long-name/long-link entries and PAX headers included; a global PAX header setting `path`, `linkpath`, or `size` is refused); `{"errors": {"body": [message]}}`; retry with a corrected archive |
| `503` + `Retry-After` | node spool budget, the account's share of it, or its concurrent upload cap exhausted, or the session's owner unavailable; retry |

This client upload is a single HTTP request and is **not** resumable. Inside
GoodFlows, delivery from the server to each member is chunked, checksummed,
and resumes after interruption (`sprite-transfer/README.md`); a member whose
delivery or extraction fails is announced `member_lost`.

## Report download

`GET /api/v1/pool-execs/{exec_id}/reports/{name}` (creating key only)
returns the report bytes as `application/x-ndjson` (any `Accept` header is
accepted).

| status | meaning |
|---|---|
| `200` | the verified file |
| `404` | unlisted name, `too_large`, or no longer a regular file within 32 MiB |
| `410` | the member started another exec or was released |
| `503` + `Retry-After` | not ready within the fetch wait (60 s), transfer capacity or the node spool budget (each download reserves 32 MiB until it is verified) exhausted, or the internal transfer failed; retry, which reuses the transfer's progress |

Every `200` carries `x-content-sha256` (lowercase hex SHA-256 of the whole
file); verify it. If the report is invalidated while it is being streamed
from another server node, the connection is dropped mid-body rather than
ended cleanly, so a truncated download always surfaces as an error.

There is no HTTP `Range` support: a dropped download is retried from the
start. Internally the report is snapshotted in the member and transferred
with chunk-level resume and a whole-file SHA-256 check before it is served.

## Sessions over REST

- `POST /api/v1/projects/{project}/pools/{pool}/sessions` with
  `{"max_members": 4, "acquire_timeout_ms": 120000, "label": "goodci"}`.
  `max_members` (1 to the pool's `max_members`) and `acquire_timeout_ms`
  (1,000 to the server maximum, 10 minutes by default) are required;
  `label` is optional (at most 255 characters, no control characters). Any
  other key, or a value out of range, is `422` naming the field. The
  response is `201` with the session wrapped in `data`:

  ```json
  {"data": {"id": "9a1b…", "status": "waiting", "end_reason": null,
            "pool": "rust-ci", "project": "app", "max_members": 4,
            "wanted": 4, "label": "goodci", "topic": "pool_session:9a1b…",
            "members": [{"id": "7c0c…", "name": "gfp-…", "ready": false}],
            "workspace_uploaded": false,
            "acquire_deadline_at": "2026-11-01T12:02:00.000000Z",
            "ended_at": null, "inserted_at": "…", "updated_at": "…"}}
  ```

  Members are granted partially and fairly: a session holding nothing is
  served before a holding session gets another member. A session that
  receives no member within `acquire_timeout_ms` expires with
  `no_member_available`.
- `GET /api/v1/pool-sessions/{id}` (any key of the account) returns the
  same `{"data": …}` shape and never returns workspace contents, commands,
  environment values, or output. Ended sessions are deleted (with their
  execs) after the retention period (30 days by default).
- `DELETE /api/v1/pool-sessions/{id}` → `204`, also for an ended session.

## Error codes summary

| where | code |
|---|---|
| join | `not_found`, `forbidden`, `ended` |
| any event (unknown, or missing keys) | `invalid_request` (`fields: []`) |
| `exec` | `invalid_request`, `not_granted`, `member_not_ready`, `member_busy`, `ended`, `draining`, `unavailable` |
| `cancel` | `not_found` |
| `resume` | `invalid_request` (over 1,000 entries) |
| `want` | `invalid_request` |
| `release_member` | `not_granted`, `unavailable` |
| `session_ended.reason` | `no_member_available`, `client_disconnected`, `lifetime_exceeded`, `key_revoked`, `session_owner_lost` |
| `exit.error_reason` | `owner_lost`, `exec_failed` |
