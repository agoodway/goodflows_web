# sprite-transfers Specification

## Purpose

Transfers workspace archives and report files between GoodFlows and a leased Sprite with bounded memory, verified integrity, and chunk-level resume after a transport interruption.

## Requirements

### Requirement: Bidirectional transfer helper
Each ready pool member MUST provide a compatible `gf-transfer` helper supporting receive, send, collect (a bounded, non-resumable outputs read and report manifest), and a version handshake. It MUST run inside the Sprite using non-TTY exec stdin/stdout for binary protocol data and stderr for diagnostics. It MUST require neither a listening service nor a Sprites credential inside the Sprite.

#### Scenario: Binary transfer in both directions
- **WHEN** GoodFlows sends a workspace archive and retrieves a report containing arbitrary binary bytes
- **THEN** the helper preserves those bytes through exec stdin/stdout and keeps diagnostics separate

### Requirement: Compatible helper before checkpoint
Provisioning MUST install an architecture-compatible helper, verify its checksum and protocol version after setup, and include it in the golden checkpoint. Provisioning MUST determine the member's architecture before bootstrap, and an unsupported architecture MUST fail provisioning with `unsupported_architecture`. A missing, corrupt, incompatible, or oversized bootstrap artifact MUST prevent the member becoming idle.

#### Scenario: Incompatible helper
- **WHEN** provisioning discovers a helper with an unsupported protocol version
- **THEN** provisioning fails with a sanitized compatibility error and the member is not grantable

### Requirement: Bounded transfer framing
Protocol v1 MUST frame an at-most-8-KiB JSON header with a four-byte big-endian length, followed by the declared raw payload. The default maximum payload MUST be 1 MiB, negotiated before data frames: the sender proposes a maximum in `open`, the receiver answers in `ready` with the lesser of that and its own maximum (at most 1 MiB), and frames above the agreed value MUST be rejected. The header limit is fixed. Implementations MUST reject invalid lengths, offsets, or versions before allocation and decode frames across arbitrary transport fragments.

#### Scenario: Fragmented frame
- **WHEN** a frame's prefix, header, and binary payload arrive in separate transport fragments
- **THEN** the receiver reconstructs exactly one frame without modifying payload bytes

#### Scenario: Oversized declaration
- **WHEN** a peer declares a header above 8 KiB or payload above the negotiated maximum
- **THEN** the receiver rejects the frame before allocating the declared size

### Requirement: Transfer identity is immutable
A transfer id MUST bind direction, session, member, lease generation, logical artifact, expected byte length, and complete SHA-256. Reusing an id with conflicting metadata MUST fail. Transfer ids MUST NOT allow client-selected paths to escape private transfer storage. For downloads, the id first binds every field except length and hash; the helper binds length and SHA-256 once when it creates the snapshot, and later reopens MUST match them.

#### Scenario: Resume against another lease
- **WHEN** a peer tries to resume an existing transfer id with a different lease generation
- **THEN** the transfer is refused and no data from the old lease is published

### Requirement: Durable chunk acknowledgements
Each chunk MUST carry its byte offset and SHA-256. The receiver MUST accept only its expected next offset, verify the chunk, durably save data and its committed boundary, then acknowledge. Initially at most one chunk MUST be in flight. Competing writers MUST NOT modify the same transfer concurrently.

#### Scenario: Crash before acknowledgement
- **WHEN** a receiver crashes after writing chunk bytes but before committing their boundary
- **THEN** reopen truncates uncommitted bytes and reports the last durable boundary for safe resend

#### Scenario: Competing writer
- **WHEN** a second invocation attempts to write an already owned transfer
- **THEN** it fails without modifying the first invocation's partial file or boundary

### Requirement: Stale helper invocations terminate
A helper invocation MUST hold its transfer ownership through an OS advisory lock released when the process exits. It MUST exit on stdin EOF, after a server-supplied idle timeout without frames, and at a server-supplied absolute deadline. The idle and extraction timeouts MUST be positive; `0` MUST be rejected as a usage error (exit status 2). A replacement invocation (including a report `send` that finds the snapshot lock held) that finds the lock held MAY wait up to the idle timeout before failing with `busy`. The idle timeout and deadline MUST also hold while the helper is blocked writing its output. The server MUST bind the deadline to the session's expiry and start no attempt after it, MUST wait for an attempt's first frame at least the idle timeout, MUST retry `busy`, and MUST send stdin EOF before abandoning an invocation.

#### Scenario: Old helper outlives a dropped connection
- **WHEN** the exec connection drops and the old helper receives neither frames nor EOF
- **THEN** it exits after the idle timeout, releasing its lock, and a new invocation resumes from the committed offset

#### Scenario: Nobody reads the helper's output
- **WHEN** the helper is blocked writing a chunk that GoodFlows never reads
- **THEN** it exits after the idle timeout (or at the deadline) all the same

### Requirement: Resume uses receiver progress
After interruption, a new helper invocation MUST resume the same transfer at the receiver's committed offset without retransmitting already acknowledged chunks. Retries MUST remain within session deadlines and owner fencing. Upload resume MUST preserve on-Sprite partials; download resume MUST preserve the coordinator's receiver spool.

#### Scenario: Lost acknowledgement
- **WHEN** the receiver commits a chunk but its acknowledgement is lost
- **THEN** reopen returns the advanced offset and the sender continues without duplicating bytes

### Requirement: Verified and idempotent completion
Finish MUST verify expected total length and complete SHA-256 before atomically publishing the received file. Repeated finish or reopen of a completed transfer MUST return the same result without republishing or extracting a successfully hydrated workspace twice. Complete-hash mismatch MUST invalidate the partial transfer and return a restart-required error.

#### Scenario: Lost completion reply
- **WHEN** publication succeeds and the connection drops before the completion reply arrives
- **THEN** retry returns the completed result without modifying the artifact again

#### Scenario: Final hash mismatch
- **WHEN** all chunks are received but the complete SHA-256 differs from the declared hash
- **THEN** no artifact is published and the transfer reports restart required

### Requirement: Workspace hydration waits for verified delivery
Workspace transfer MUST use disk spooling and the configured compressed-size limit (default 256 MiB). The helper MUST enforce expanded-size, entry-count, path/type/link confinement, and deadline limits before extraction. Only a verified and successfully extracted workspace under the current lease generation permits readiness. Extraction failure MUST quarantine the member for reset rather than resume partial extraction. Delivery that cannot complete within its retry budget or the session deadline, or that fails for staging disk-full or restart-required integrity errors, MUST follow the pool-sessions hydration-failure rule.

#### Scenario: Workspace larger than filesystem write limit
- **WHEN** a valid 20 MiB archive is delivered to a leased member
- **THEN** it is transferred in bounded chunks over exec without a whole-archive filesystem API write and becomes ready only after verification and extraction

### Requirement: Downloads resume from immutable snapshots
Sending a report MUST use a private immutable snapshot of a server-authorized direct regular file, with its length and SHA-256 fixed before transfer. Symlinks (including a symlinked exec or reports directory), special files, and reports over 32 MiB MUST be refused. A resumed transfer MUST read the same snapshot rather than resolve the source path again. Receiver progress bound to another length or hash MUST be refused with `metadata_mismatch` and discarded, and every frame MUST carry the transfer's id.

#### Scenario: Source changes after snapshot
- **WHEN** report delivery is interrupted and its source file later changes
- **THEN** resume delivers bytes from the original snapshot with the original hash

### Requirement: Transfer state follows lease lifetime
Member release/reset or session expiry MUST stop transfer invocations and invalidate their state before member reuse. Before every workspace transfer attempt (including retries), the server MUST check that the member is still leased to the session under the transfer's lease generation, and MUST NOT start the attempt otherwise. Next exec MUST also invalidate report transfers. Coordinator loss MUST follow session-owner-loss expiry. Eligible completed transfers MUST remain retryable within their lifetime. Cleanup MUST remove private partials, snapshots, and terminal-session server spools.

#### Scenario: Release during transfer
- **WHEN** a session releases a member while a transfer is incomplete
- **THEN** transfer work is stopped or fenced before reset and a later lease cannot resume its partial data

#### Scenario: Orphaned retry after release
- **WHEN** a workspace transfer attempt fails and, before its retry, the member is released and leased again
- **THEN** the retry does not start, so the old session's workspace never reaches the new lease

### Requirement: Resume scope excludes client HTTP hops
Resume in this capability MUST apply only between GoodFlows and the Sprite. The initial client workspace HTTP upload MUST retain its once-only upload contract, and client report downloads MUST retain their existing HTTP contract without a promise of Range resume. Report bytes MUST be verified in the server spool before HTTP delivery and retain the existing 404 and 410 rules.

#### Scenario: Retry client report download after internal transfer drop
- **WHEN** the internal Sprite transfer resumes and completes while the report remains valid
- **THEN** the client receives the verified complete report through the existing HTTP endpoint
