# Proposal

## Why

`goodci` (the `goodflows` CLI) runs every job on the machine that invokes it, so agents iterating on uncommitted changes and CI on pushed commits are limited to local CPU and local toolchains. GoodFlows already holds each account's Sprites credential and executes bounded commands in Sprite VMs, so it can lend pre-built VMs to `goodci` and run individual jobs on them without the Sprites token ever leaving the server.

## What Changes

- Add project-scoped **pools**: a named set of Sprite VMs ("members") built from a pool `setup` list, with `min_ready` and `max_members`. Pools are managed over `/api/v1/projects/:project/pools` with private-key writes.
- Each member runs the pool setup once, takes its own golden checkpoint, and is restored to that checkpoint after every lease. A background reconciler keeps `min_ready` idle members built, grows on demand up to `max_members`, rebuilds members whose setup is stale after a pool update, and retires broken members.
- Add **pool sessions**: one `goodci` invocation acquires a session, receives members by partial grant (at least one within a client-chosen wait, more as they free up, fairly across waiting sessions), uploads its working tree once as a tarball, which the server extracts into every granted member, and releases the session at the end. A session with no connected client for a grace period expires and its members are reset.
- Add a small Rust **`gf-transfer` helper inside each Sprite**, installed before its golden checkpoint. GoodFlows streams workspace archives and report files through the exec WebSocket in bounded, checksummed chunks, resuming from the receiver’s durable acknowledged offset after interruption. This replaces whole-archive filesystem API writes; no service or Sprites token is installed inside the VM.
- Add **pool execs** over a Phoenix Channels WebSocket at `/api/v1/socket`. The client starts one command at a time per member, receives seq-numbered stdout/stderr chunks, an exit event with the exit status and the `GOODFLOWS_OUTPUT` file, and a manifest of test report files it downloads over HTTP. Execs keep running across brief disconnects and replay buffered output on rejoin. An explicit cancel kills an exec.
- Reserve the sprite name prefix `gfp-` for pool members. Recipe names and run sprite names may no longer use it. **BREAKING** for any existing recipe whose name or expanded sprite name starts with `gfp-`.
- A project with pools can no longer be deleted.

## Capabilities

### New Capabilities

- `sprite-pools`: pool definition and CRUD, member lifecycle (provision, golden checkpoint, reset, stale, broken), and capacity reconciliation.
- `pool-sessions`: session acquisition with partial grant and fairness, workspace upload, liveness and expiry, member release, and session records.
- `sprite-transfers`: bidirectional binary transfers between GoodFlows and a leased Sprite, chunk acknowledgements, resume, integrity, limits, helper compatibility, and lifecycle cleanup.
- `pool-execs`: the WebSocket channel contract for running commands on leased members, including streaming output, replay, cancel, timeouts, the outputs file, and test report retrieval.

### Modified Capabilities

- `spry-recipes`: recipe name templates must not start with the reserved `gfp-` prefix.
- `spry-templates`: an expanded sprite name, or a `sprite` override, must not start with `gfp-`.
- `projects`: deletion protection extends to projects that have pools.

## Impact

- New context modules, schemas and migrations for pools, members, sessions and execs. New PgFlow jobs for member provisioning and reset, plus a leader-elected reconciler tick alongside `GoodFlows.Spry.ReaperScheduler`.
- `GoodFlows.Spry.Sprites` gains checkpoint create/restore, a size-checked filesystem write for helper bootstrap, a binary streaming exec with separate stdout/stderr, and a bounded duplex `transfer/5` exec (stdin writes/EOF) for `gf-transfer`. It stays the only module that talks to the Sprites SDK.
- New `GoodFlowsWeb` socket and channel at `/api/v1/socket`, and new REST controllers with OpenAPI schemas. The workspace upload route gets its own body handling, as test report uploads already do.
- New `sprite-transfer/` Rust crate producing `gf-transfer`, plus versioned Linux release binaries and provisioning-time checksum/version verification. Workspace delivery keeps the 256 MiB compressed default; transfers use 1 MiB chunks and SHA-256 without buffering complete files. Resume covers GoodFlows ↔ Sprite only; initial client HTTP upload and client report downloads keep their existing contract.
- New runtime config for pool limits (member cap, upload size, archive expanded-size, entry and deadline limits, transfer chunk size and concurrency, session grace and lifetime, exec timeout, output buffer, report limits).
- Companion client: a `goodci` change (to be proposed in `../goodci`) adds `[remote]` configuration, a remote executor behind a transport trait using `phoenix-channel-runtime`, working-tree tarball upload, and pulling reports back into the local job directory so the existing `upload-test-timings` collector is unchanged. This change owns the wire contract.
