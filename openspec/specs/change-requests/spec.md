# change-requests Specification

## Purpose

Stores change requests, the records that replace pull requests: their lifecycle, the Git facts and claims a client reports for each head, and the verdict the server computes from those facts and the project's review policy so clients know whether a person needs to look.

## Requirements

### Requirement: Change request routes require a key of the account
Every route under `/api/v1/projects/:project/change-requests` SHALL require a valid API key for the project's account. Missing, expired or revoked keys MUST return `401`. `ck_` keys MUST return `403` on every route. `pk_` keys MUST be allowed, with redaction, on `GET` routes, and MUST return `403` on every other route. An invalid project slug returns `422` on `project`; an unknown slug returns `404`.

#### Scenario: Private key opens a change request
- **WHEN** a client with an `sk_` key posts a valid change request to project `goodcases` of its account
- **THEN** the API responds `201`

#### Scenario: Public key reads
- **WHEN** a client with a `pk_` key lists the change requests of project `goodcases`
- **THEN** the API responds `200`

#### Scenario: Public key cannot write
- **WHEN** a client with a `pk_` key creates a change request, reports Git facts, uploads claims, or changes a state
- **THEN** the API responds `403`, does not read the body, and stores nothing

#### Scenario: Cache key
- **WHEN** a client with a `ck_` key bound to project `goodcases` lists that project's change requests
- **THEN** the API responds `403`

#### Scenario: Missing key
- **WHEN** a client with no key, an expired key, or a revoked key shows change request `1`
- **THEN** the API responds `401`

#### Scenario: Other account's project
- **WHEN** a client lists change requests of a slug that exists only on another account
- **THEN** the API responds `404`

### Requirement: Authentication and resolution happen before the body is read
On every write route, authentication, project resolution and change request resolution MUST finish before the body is read. A `:number` path segment that is not a positive integer MUST return `422` on `number`. A number with no change request in the project MUST return `404`. A request whose `Accept` header does not allow `application/json` MUST return `406` before the body is read.

#### Scenario: Unknown number
- **WHEN** a client with an `sk_` key posts Git facts to change request `999` of a project that has 3 change requests
- **THEN** the API responds `404` without reading the body

#### Scenario: Invalid number
- **WHEN** a client shows change request `abc` or `0`
- **THEN** the API responds `422` with an error on `number`

#### Scenario: Unacceptable Accept
- **WHEN** a client shows a change request with `Accept: text/plain`
- **THEN** the API responds `406`

### Requirement: Change requests are opened as drafts with a per-project number
`POST /api/v1/projects/:project/change-requests` SHALL create a change request in state `draft` and respond `201` with it. Each change request MUST get the next `number` of its project, starting at `1`. Numbers MUST never be reused, including after a change request is closed. Concurrent creates MUST get distinct numbers. The change request MUST record the membership and key that opened it.

#### Scenario: First change request
- **WHEN** a client with an `sk_` key creates a change request in a project that has none
- **THEN** the API responds `201` with `number` `1` and `state` `draft`

#### Scenario: Numbers count up after a close
- **WHEN** a project has change requests `1` and `2`, `2` is closed, and a client creates another
- **THEN** the new change request has `number` `3`

#### Scenario: Concurrent creates
- **WHEN** two clients create a change request in the same project at the same time
- **THEN** both respond `201` with different numbers

#### Scenario: Numbers are per project
- **WHEN** project `alpha` has change request `1` and a client creates the first change request in project `beta`
- **THEN** the new change request has `number` `1`

### Requirement: Change request fields are validated
The create body MUST accept only `title` (required, 1 to 256 UTF-8 bytes, no control characters), `source_branch` (required) and `target_branch` (optional, defaults to the project's `default_branch`), both 1 to 256 UTF-8 bytes with no control characters, `openspec_change` (optional, 1 to 64 bytes matching `[a-z0-9][a-z0-9-]*`), and `links` (optional, the workflow-run `links` shape). Any other key or a rule violation MUST return `422` on that key.

#### Scenario: Default target branch
- **WHEN** a client creates `{"title": "Add login", "source_branch": "feat/login"}` in a project whose `default_branch` is `trunk`
- **THEN** the API responds `201` with `target_branch` `trunk`

#### Scenario: Linked OpenSpec change and links
- **WHEN** a client creates a change request with `openspec_change` `add-login` and `links` `{"tickets": ["GOO-291"]}`
- **THEN** the API responds `201` and stores both as given

#### Scenario: Several OpenSpec changes
- **WHEN** a client creates a change request with `openspec_change` `["add-login", "add-logout"]`
- **THEN** the API responds `422` with an error on `openspec_change` and stores nothing

#### Scenario: Unknown key
- **WHEN** a client creates a change request with a `state` key
- **THEN** the API responds `422` with `has an unknown field` on `body` and stores nothing

#### Scenario: Invalid title
- **WHEN** a client creates a change request whose `title` is empty, contains a newline, or is 257 bytes long
- **THEN** the API responds `422` with an error on `title` and stores nothing

#### Scenario: Empty links
- **WHEN** a client creates a change request with `links` `{}`
- **THEN** the API responds `422` with an error on `links` and stores nothing

### Requirement: Change request responses carry the record
A change request response MUST include under `data` the `id`, `number`, `title`, `state`, `source_branch`, `target_branch`, `openspec_change` (or null), `links` (or null), `head` (the last reported head, or null), `opened_by` with the opener's `user_id`, `merge` (null unless merged), `inserted_at` and `updated_at`. It MUST NOT include `account_id` or `project_id`.

#### Scenario: New change request
- **WHEN** a client creates a change request without Git facts
- **THEN** the response has `head` null, `merge` null, and `opened_by.user_id` equal to the key owner's user id

### Requirement: List change requests
`GET /api/v1/projects/:project/change-requests` SHALL return the project's change requests ordered by `number` descending, keyset-paged with `limit` (1 to 200, default 50) and `cursor` (the previous page's `next_cursor`, null on the last page). It SHALL accept the exact-match filters `state` and `source_branch`, combined with AND. A filter, `limit` or `cursor` that breaks its rule MUST return `422` on that parameter.

#### Scenario: Paged list
- **WHEN** a project has change requests `1` to `3` and a client lists with `limit=2`, then with the returned cursor
- **THEN** the first page has `3` and `2` and a `next_cursor`, and the second has `1` and `next_cursor` null

#### Scenario: Filter by state
- **WHEN** a project has change requests in `draft`, `open` and `merged` and a client lists with `state=open`
- **THEN** the response contains only the `open` change request

#### Scenario: Unknown state filter
- **WHEN** a client lists with `state=approved`
- **THEN** the API responds `422` with an error on `state`

### Requirement: Show a change request
`GET /api/v1/projects/:project/change-requests/:number` SHALL return the change request with its `description`, its current `verdict`, and its `history` of state changes oldest first. `description` MUST be the Markdown of the claims stored for the current head, or null when there are none.

#### Scenario: Show with claims
- **WHEN** a change request has Git facts and claims for head `H` and a client shows it
- **THEN** the API responds `200` with `description` equal to the uploaded Markdown file and `verdict.head` `H`

#### Scenario: Show after the head moved
- **WHEN** claims exist for head `H1` and a client reports Git facts for head `H2`, then shows the change request
- **THEN** `description` is null and `head` is `H2`

### Requirement: Change request states and transitions
A change request SHALL be in exactly one of `draft`, `open`, `merged` or `closed`. `POST .../change-requests/:number/ready` MUST move `draft` to `open`, `.../draft` MUST move `open` to `draft`, `.../close` MUST move `draft` or `open` to `closed`, and `.../reopen` MUST move `closed` back to the state it had when closed. A request for the current state MUST respond `200` and record nothing. Any other transition MUST respond `409`.

#### Scenario: Ready a draft
- **WHEN** a client with an `sk_` key posts `ready` for a `draft` change request
- **THEN** the API responds `200` with `state` `open`

#### Scenario: Back to draft
- **WHEN** a client posts `draft` for an `open` change request
- **THEN** the API responds `200` with `state` `draft`

#### Scenario: Reopen restores the previous state
- **WHEN** an `open` change request is closed and a client posts `reopen`
- **THEN** the API responds `200` with `state` `open`

#### Scenario: Ready while open
- **WHEN** a client posts `ready` for an `open` change request
- **THEN** the API responds `200` with `state` `open` and no state change is recorded

#### Scenario: Ready a closed change request
- **WHEN** a client posts `ready` for a `closed` change request
- **THEN** the API responds `409` and the state stays `closed`

#### Scenario: Merged is terminal
- **WHEN** a client posts `close`, `reopen`, `ready` or `draft` for a `merged` change request
- **THEN** the API responds `409` and the state stays `merged`

### Requirement: Any private key of the account may change the state
Every state change, including a merge report, SHALL be allowed for any `sk_` key of the account regardless of the membership's role, and MUST NOT require the key that opened the change request. Each recorded change MUST store the previous state, the new state, the membership, the key and the time, and MUST appear in the show response's `history`.

#### Scenario: Member closes another member's change request
- **WHEN** user A opens a change request and user B, a plain member, closes it with an `sk_` key
- **THEN** the API responds `200` and `history` ends with an entry from `draft` to `closed` naming B's `user_id`

### Requirement: A merge report records the merge
`POST .../change-requests/:number/merged` SHALL accept only `merged_commit` (40 or 64 lowercase hex characters) and `target_branch` (1 to 256 UTF-8 bytes, no control characters), both required, and, once `add-change-request-merge` ships, an optional `lease_id`. It is accepted from `draft` or `open` and moves the change request to `merged`.

#### Scenario: Merge an open change request
- **WHEN** an `open` change request has a `mergeable` verdict and a client reports `{"merged_commit": "<40-hex>", "target_branch": "main"}`
- **THEN** the API responds `200` with `state` `merged`, `merge.verdict_state` `mergeable`, and `merge.merged_without_mergeable_verdict` false

#### Scenario: Merge a draft
- **WHEN** a client reports a merge for a `draft` change request
- **THEN** the API responds `200` with `state` `merged`

#### Scenario: Merge a closed change request
- **WHEN** a client reports a merge for a `closed` change request
- **THEN** the API responds `409` and the state stays `closed`

#### Scenario: Invalid merged commit
- **WHEN** a client reports a merge with `merged_commit` `ABC123`
- **THEN** the API responds `422` with an error on `merged_commit` and the state is unchanged

### Requirement: The merge record keeps the verdict at merge
The response's `merge` MUST hold `merged_commit`, `target_branch`, `merged_at`, the `head`, the `verdict_state`, `policy_version` and `reasons` of the verdict at that head, `merged_without_mergeable_verdict`, and, from `add-change-request-merge`, `merged_without_lease`. These values MUST NOT change after the merge is recorded.

#### Scenario: Verdict stored with the merge
- **WHEN** an `open` change request whose verdict at head `H` is `needs_review` under policy version `4` with one `one_way_door` reason is reported merged
- **THEN** `merge` has `head` `H`, `verdict_state` `needs_review`, `policy_version` `4`, and `reasons` with that `one_way_door` reason

#### Scenario: Merge record after a policy change
- **WHEN** a change request was merged under policy version `4` and an admin then writes version `5`
- **THEN** its `merge.policy_version` is still `4` and `merge.reasons` are unchanged

### Requirement: A merge without a mergeable verdict is flagged, not rejected
A merge report MUST be accepted whatever the verdict. When the verdict state at the head is not `mergeable`, or the change request has no head, the merge MUST be stored with `merged_without_mergeable_verdict` true. The flag and the stored verdict state MUST NOT change afterwards.

#### Scenario: Merge while needs_review
- **WHEN** a client reports a merge for a change request whose verdict is `needs_review`
- **THEN** the API responds `200` with `state` `merged`, `merge.verdict_state` `needs_review`, and `merge.merged_without_mergeable_verdict` true

#### Scenario: Merge without Git facts
- **WHEN** a client reports a merge for a change request that has no Git facts
- **THEN** the API responds `200` with `merge.head` null, `merge.verdict_state` `pending`, and `merge.merged_without_mergeable_verdict` true

### Requirement: Merge reports are idempotent
A merge report for a `merged` change request whose `merged_commit` and `target_branch` equal the stored ones MUST respond `200` with the stored merge and change nothing, whatever else it carries; a retry never re-evaluates the stored flags. One that differs MUST respond `409` and change nothing.

#### Scenario: Retried merge report
- **WHEN** a client reports the same merge twice
- **THEN** both respond `200` with the same `merge.merged_at`

#### Scenario: Different merged commit
- **WHEN** a change request was merged with commit `C1` and a client reports a merge with commit `C2`
- **THEN** the API responds `409` and the stored merge still names `C1`

### Requirement: Git facts are reported once per head and target branch
`POST .../change-requests/:number/git-facts` SHALL accept one `git-facts/1` document per head and `target.branch` of a `draft` or `open` change request. A first report MUST respond `201` and make its head current. An equal report (canonical JSON digest) MUST respond `200`, store nothing, and make its head current again. A different report for a stored pair MUST respond `409`. The verdict MUST use only the report for the current head and `target_branch`.

#### Scenario: First report
- **WHEN** a client reports Git facts for head `H1` on a `draft` change request
- **THEN** the API responds `201` and the change request's `head` is `H1`

#### Scenario: Exact retry
- **WHEN** a client reports the same document for the current head `H1` again with object keys in a different order
- **THEN** the API responds `200` and nothing changes

#### Scenario: Different report for the same head
- **WHEN** Git facts for `H1` are stored and a client reports `H1` with a different `target.merge_base`
- **THEN** the API responds `409` and the stored report is unchanged

#### Scenario: The base moved
- **WHEN** a client reports `H1`, then `H2`
- **THEN** both respond `201` and the change request's `head` is `H2`

#### Scenario: Re-reporting an earlier head
- **WHEN** a client reports `H1`, then `H2`, then the identical `H1` document again
- **THEN** the third report responds `200` and the change request's `head` is `H1`

#### Scenario: Same head, another target branch
- **WHEN** Git facts for `H1` targeting `a` are stored, the change request's `target_branch` becomes `main` (a retarget, see `add-change-request-merge`), and a client reports `H1` targeting `main`
- **THEN** the API responds `201`, both reports are kept, and the verdict uses the `main` report

#### Scenario: Closed change request
- **WHEN** a client reports Git facts for a `closed` or `merged` change request
- **THEN** the API responds `409` and stores nothing

### Requirement: Git facts documents are validated
A `git-facts/1` document MUST contain only `format` (`git-facts/1`), `head`, `target` (only `branch` and `merge_base`), `commits` and `diff` (only `files`). Every SHA MUST be 40 or 64 lowercase hex characters. `target.branch` MUST equal the change request's `target_branch`. `commits` MUST be oldest first and its last `sha` MUST equal `head`; it MAY be empty only when `head` equals `target.merge_base`. Violations MUST return `422` on the key.

#### Scenario: Wrong format
- **WHEN** a document has `format` `git-facts/2`
- **THEN** the API responds `422` with an error on `format` and stores nothing

#### Scenario: Target branch mismatch
- **WHEN** a change request targets `main` and a document has `target.branch` `release`
- **THEN** the API responds `422` with an error on `target.branch` and stores nothing

#### Scenario: Last commit is not the head
- **WHEN** a document's last commit `sha` differs from `head`
- **THEN** the API responds `422` with an error on `commits` and stores nothing

#### Scenario: Uppercase SHA
- **WHEN** a document's `head` contains uppercase hex digits
- **THEN** the API responds `422` with an error on `head`

### Requirement: Git facts file entries are validated
Each commit MUST contain only `sha`, `parents` (a nonempty array of SHAs) and `changed_files`. Each file entry in `changed_files` and `diff.files` MUST contain `path`, `status` (`added`, `modified`, `deleted`, `renamed`, `copied` or `type_changed`), and nonnegative integer `additions` and `deletions`. `old_path` MUST be present for `renamed` and `copied` and absent otherwise. Paths MUST be 1 to 4,096 bytes, relative, without control characters, and unique within a list.

#### Scenario: Rename without old path
- **WHEN** a `diff.files` entry has `status` `renamed` and no `old_path`
- **THEN** the API responds `422` with an error on `diff.files[<index>].old_path`

#### Scenario: Old path on a modified file
- **WHEN** a `diff.files` entry has `status` `modified` and an `old_path`
- **THEN** the API responds `422` with an error on `diff.files[<index>].old_path`

#### Scenario: Unknown status
- **WHEN** a file entry has `status` `unmerged`
- **THEN** the API responds `422` with an error on that entry's `status`

#### Scenario: Absolute path
- **WHEN** a `diff.files` entry has `path` `/etc/passwd`
- **THEN** the API responds `422` with an error on `diff.files[<index>].path`

#### Scenario: Duplicate path
- **WHEN** `diff.files` lists `lib/a.ex` twice
- **THEN** the API responds `422` with an error on `diff.files`

### Requirement: Git facts are limited in size
A `git-facts/1` document MUST have at most 1,000 `commits`, at most 10,000 `diff.files`, and at most 10,000 `changed_files` per commit. A document over any limit MUST return `422` on that key and store nothing.

#### Scenario: Too many commits
- **WHEN** a document has 1,001 commits
- **THEN** the API responds `422` with an error on `commits` and stores nothing

#### Scenario: Too many files
- **WHEN** a document's `diff.files` has 10,001 entries
- **THEN** the API responds `422` with an error on `diff.files` and stores nothing

#### Scenario: At the limits
- **WHEN** a document has 1,000 commits and 10,000 `diff.files`
- **THEN** the API responds `201`

### Requirement: JSON upload bodies are strict
JSON bodies on change request routes MUST follow the workflow-run upload rules: a body over a server-configured limit (default 16 MiB for Git facts, 1 MiB for scenario sets, 64 KiB otherwise) returns `413`, a non-JSON Content-Type or a Content-Encoding other than `identity` returns `415`, malformed JSON returns `400`, and duplicate keys, U+0000 in a string, non-integer numbers, and integers above 2^53-1 return `422`. Validation errors MUST NOT echo submitted values.

#### Scenario: Duplicate key
- **WHEN** a Git facts document contains the key `head` twice
- **THEN** the API responds `422` with `has a duplicate key` on `body` and stores nothing

#### Scenario: Oversized Git facts
- **WHEN** a client declares a Content-Length one byte over the Git facts limit
- **THEN** the API responds `413` without reading the body and stores nothing

#### Scenario: Oversized scenario set
- **WHEN** a client uploads a scenario set body of 1,048,577 bytes
- **THEN** the API responds `413` and stores nothing

#### Scenario: Malformed JSON
- **WHEN** a client creates a change request with the body `{`
- **THEN** the API responds `400` and stores nothing

### Requirement: Claims are uploaded once per head
`POST .../change-requests/:number/claims` SHALL accept one `change-claims/2` Markdown file (`Content-Type: text/markdown`, UTF-8, at most 1 MiB by default) per head of a `draft` or `open` change request, and store the raw file. The first upload for a head MUST respond `201`. An identical file MUST respond `200` and change nothing. A different file for a head with stored claims MUST respond `409`.

#### Scenario: Upload claims
- **WHEN** a client uploads a valid claims file for the current head `H1`
- **THEN** the API responds `201` and stores the file byte for byte

#### Scenario: Identical retry
- **WHEN** a client uploads the same file for `H1` again
- **THEN** the API responds `200` and nothing changes

#### Scenario: Different claims for the same head
- **WHEN** claims for `H1` are stored and a client uploads a file for `H1` with a different `reach`
- **THEN** the API responds `409` and the stored claims are unchanged

#### Scenario: Wrong content type
- **WHEN** a client uploads claims with `Content-Type: application/json`
- **THEN** the API responds `415` and stores nothing

#### Scenario: Claims on a closed change request
- **WHEN** a client uploads claims for a `closed` or `merged` change request
- **THEN** the API responds `409` and stores nothing

### Requirement: Claims front matter is validated
The file MUST start with a YAML front matter block between `---` lines, followed by the Markdown body. The front matter MUST be a mapping with only `format` (`change-claims/2`), `cr`, `head`, `door`, `door_reason`, `reach`, `safe_because`, `left_open`, `questions` and `decisions`, all required; another `format` gets `422` on `format`. YAML anchors, aliases and tags MUST be rejected. The server MUST NOT parse or validate the body. Violations MUST return `422` on the key.

#### Scenario: No front matter
- **WHEN** a file does not start with a `---` line
- **THEN** the API responds `422` with an error on `front_matter` and stores nothing

#### Scenario: Unknown front matter key
- **WHEN** the front matter has a `reviewers` key
- **THEN** the API responds `422` with `has an unknown field` on `front_matter` and stores nothing

#### Scenario: YAML alias
- **WHEN** the front matter uses an anchor `&a` and an alias `*a`
- **THEN** the API responds `422` on `front_matter` and stores nothing

#### Scenario: Server rejects change-claims/1
- **WHEN** the front matter has `format` `change-claims/1`
- **THEN** the API responds `422` with an error on `format` and stores nothing

### Requirement: Claims front matter is one bounded YAML document
The front matter MUST be a single YAML document, MUST NOT repeat a key within one mapping, and MUST NOT nest collections (block or flow) more than 16 levels deep, counting the front matter mapping. Unless the front matter is a JSON object, a flow collection that is not a mapping value MAY be rejected once the parser holds more than 256 of its tokens. Each MUST return `422` on `front_matter` with a fixed message that does not echo the input.

#### Scenario: Front matter nested too deep
- **WHEN** the front matter has a key whose value is 16 nested flow sequences (`x: [[[…]]]`), 17 levels with the mapping
- **THEN** the API responds `422` on `front_matter` and stores nothing

#### Scenario: Duplicate front matter key
- **WHEN** the front matter has `door: two_way` and then `door: one_way` in the same mapping
- **THEN** the API responds `422` with `has a duplicate key` on `front_matter` and stores nothing

#### Scenario: Second YAML document
- **WHEN** the front matter has `door: two_way`, a `...` line, a `--- ` line (with a trailing space) and `door: one_way`
- **THEN** the API responds `422` with `must be a single YAML document` on `front_matter` and stores nothing

### Requirement: Claims front matter integers are bounded
The front matter MUST be resolved with the YAML 1.2 core schema, even under a `%YAML 1.1` directive. A plain scalar that schema reads as an integer (optional sign, then decimal digits, `0x` hex digits or `0o` octal digits) MUST NOT have more than 32 digits, since accepted integers stay within `±(2^53 - 1)`; it MUST return `422` on `front_matter` with a fixed message before the value is built. Every other plain scalar MUST resolve as without this rule.

#### Scenario: Huge integer
- **WHEN** the front matter has `x:` followed by 200,000 plain decimal digits
- **THEN** the API responds `422` with `must not have an integer of more than 32 digits` on `front_matter` and stores nothing

#### Scenario: Plain SHA stays a string
- **WHEN** the front matter has a plain, unquoted `head` of 40 hex characters that starts with a digit and contains a letter
- **THEN** `head` is read as that string

### Requirement: Claims front matter fields are validated
`cr` MUST be an integer equal to the change request's number, or null. `door` MUST be `one_way` or `two_way`. `door_reason` and `reach` MUST be nonempty strings. `safe_because` MUST have 1 to 100 entries; `left_open` 0 to 100 of `{risk, location, affected}`; `questions` 0 to 50 of `{id, text, options, recommendation}`; `decisions` 0 to 3 of `{id, path, hunk, note}`. Ids MUST be unique per list.

#### Scenario: Wrong number
- **WHEN** claims for change request `42` have `cr` `41`
- **THEN** the API responds `422` with an error on `cr`

#### Scenario: Nothing makes it safe
- **WHEN** the front matter has `safe_because` `[]`
- **THEN** the API responds `422` with an error on `safe_because`

#### Scenario: Four decisions
- **WHEN** the front matter has 4 `decisions`
- **THEN** the API responds `422` with an error on `decisions`

#### Scenario: Recommendation not among options
- **WHEN** a question has `options` `["a", "b"]` and `recommendation` `c`
- **THEN** the API responds `422` with an error on `questions[<index>].recommendation`

#### Scenario: Null cr
- **WHEN** valid claims have `cr` null
- **THEN** the API responds `201`

### Requirement: Safe-because entries are validated
Each `safe_because` entry MUST have `fact`, `location` and `proof`, and MAY have `evidence` and `covers`, and no other key. `fact` and `location` MUST be nonempty strings. `evidence` MUST be a list of at most 20 repo-relative strings of 1 to 1,024 bytes without control characters, such as a `.verify/<app>/<run-id>/...` path, a `run.md#<scenario id>` reference, or a test as `file:line`. `covers` MUST be `{capability, requirement, scenario}`, each a nonempty string.

#### Scenario: Incomplete covers
- **WHEN** a `safe_because` entry has `covers` `{"capability": "exports", "requirement": "Export is audited"}`
- **THEN** the API responds `422` with an error on `safe_because[<index>].covers`

#### Scenario: Absolute evidence path
- **WHEN** an `evidence` entry is `/etc/passwd`
- **THEN** the API responds `422` with an error on `safe_because[<index>].evidence`

### Requirement: A ran proof names its evidence
A `safe_because` entry with `proof` `ran` MUST have nonempty `evidence`; otherwise the upload MUST return `422` on `safe_because[<index>].evidence` and store nothing. Whether an `evidence` path or reference exists MUST NOT be checked.

#### Scenario: Ran without evidence
- **WHEN** a `safe_because` entry has `proof` `ran` and no `evidence`, or `evidence` `[]`
- **THEN** the API responds `422` with an error on `safe_because[<index>].evidence` and stores nothing

#### Scenario: Ran with evidence
- **WHEN** a `safe_because` entry has `proof` `ran` and `evidence` `[".verify/web/r1/run.md#S1", "app/test/good_flows/caches_test.exs:42"]`
- **THEN** the API responds `201`

#### Scenario: Evidence paths not checked
- **WHEN** an `evidence` entry names `.verify/web/missing/run.md`
- **THEN** the API responds `201`

### Requirement: Claims are checked against the reported head
The server SHALL make exactly three checks against stored facts: `head` MUST equal the change request's current head, every `decisions[].path` MUST appear as a `path` or `old_path` in that head's `diff.files`, and every `safe_because[].proof` MUST be `stated`, `pointed`, `walked` or `ran`. A failed check MUST return `422` on the key and store nothing. Whether a `location` names a real line MUST NOT be checked.

#### Scenario: Claims for another head
- **WHEN** the change request's head is `H2` and a client uploads claims with `head` `H1`
- **THEN** the API responds `422` with an error on `head` and stores nothing

#### Scenario: Claims before Git facts
- **WHEN** a change request has no Git facts and a client uploads claims
- **THEN** the API responds `422` with an error on `head` and stores nothing

#### Scenario: Decision outside the diff
- **WHEN** a decision names `lib/other.ex` and the head's diff does not list it
- **THEN** the API responds `422` with an error on `decisions[<index>].path`

#### Scenario: Unknown proof level
- **WHEN** a `safe_because` entry has `proof` `tested`
- **THEN** the API responds `422` with an error on `safe_because[<index>].proof`

#### Scenario: Location not checked
- **WHEN** a `safe_because` entry has `location` `lib/missing.ex:999`
- **THEN** the API responds `201`

### Requirement: Claims for an older head are kept and not used
Stored claims MUST stay stored when the head moves. Only claims whose head equals the change request's current head SHALL be used for the description and the verdict.

#### Scenario: Head moves after claims
- **WHEN** claims for `H1` are stored and a client reports Git facts for `H2`
- **THEN** the claims for `H1` can still be read and the verdict has a `claims_missing` reason

### Requirement: Read Git facts and claims
`GET .../change-requests/:number/git-facts/:head` and `GET .../change-requests/:number/claims/:head` SHALL return the stored document for that head with the uploading `user_id` and the upload time. Claims MUST be returned as the raw `document` and the parsed `front_matter`. Git facts MUST also carry `totals` (`files`, `additions`, `deletions` over `diff.files`). A head with nothing stored MUST return `404`. A malformed head MUST return `422` on `head`.

#### Scenario: Read claims
- **WHEN** claims for `H1` are stored and a client with an `sk_` key reads them
- **THEN** the API responds `200` with `document` equal to the uploaded file and `front_matter.head` `H1`

#### Scenario: Git facts totals
- **WHEN** a report for `H1` has two `diff.files` with 10 and 5 additions and 2 and 0 deletions
- **THEN** the read has `totals` `{"files": 2, "additions": 15, "deletions": 2}`

#### Scenario: No facts for the head
- **WHEN** a client reads Git facts for a head that was never reported
- **THEN** the API responds `404`

#### Scenario: Facts for another target branch
- **WHEN** Git facts for `H1` are stored for targets `a` and `main` (after a retarget, see `add-change-request-merge`), the change request targets `main`, and a client reads `git-facts/H1` without and then with `?target=a`
- **THEN** the first read returns the `main` report and the second returns the `a` report

### Requirement: Public keys see redacted change request data
Responses to a `pk_` key SHALL be redacted without changing stored rows or adding absent fields: every `user_id`, and `links.threads` when present, is null; the show response's `description` is null; claims reads have `document` null and `front_matter` with only `format`, `cr`, `head` and `door`; Git facts reads have every commit's `changed_files` and `diff.files` null; reasons in the verdict and in `merge` keep `rule` and `outcome` with `subject` and `message` null.

#### Scenario: Public key reads claims
- **WHEN** claims for `H1` with `door` `one_way` are stored and a client with a `pk_` key reads them
- **THEN** the API responds `200` with `document` null and `front_matter` `{"format": "change-claims/2", "cr": 42, "head": "H1", "door": "one_way"}`

#### Scenario: Public key reads Git facts
- **WHEN** a client with a `pk_` key reads Git facts for `H1`
- **THEN** the response keeps `head`, `target`, `totals` and each commit's `sha` and `parents`, and has `diff.files` and every commit's `changed_files` null

#### Scenario: Public key reads the verdict
- **WHEN** a client with a `pk_` key reads a verdict with a `path_match` reason
- **THEN** that reason has its `rule` and `outcome`, and `subject` and `message` null, and a later `sk_` read returns them as stored

#### Scenario: Public key shows a change request
- **WHEN** a client with a `pk_` key shows a change request with claims for its head
- **THEN** `description` and `opened_by.user_id` are null and the history entries have `user_id` null

### Requirement: The verdict has four states
A change request's verdict SHALL have `state` `pending` (an input is missing at the head), `blocked` (an input fails), `needs_review` (rules fired that need a person) or `mergeable` (no rule fired, or every reason is a `needs_review` reason cleared by an answer at the head, see `add-change-request-review`). It MUST carry the `head` (or null), the `policy_version`, `reasons`, the input digests under `inputs`, and `computed_at`. A verdict is computed in `draft` and `open`.

#### Scenario: Nothing fired
- **WHEN** a change request has Git facts and claims for head `H`, every required workflow passed on `H`, and no rule fires
- **THEN** the verdict is `mergeable` with `reasons` `[]`, `head` `H`, and the project's current policy version

#### Scenario: Verdict on a draft
- **WHEN** a `draft` change request gets Git facts and claims
- **THEN** its verdict is computed and is not `pending` because of the state

### Requirement: The verdict takes the highest-precedence outcome
The verdict `state` MUST be the highest-precedence outcome of all rules that fired, with precedence `pending`, then `blocked`, then `needs_review`, and `mergeable` when no rule fired or every reason that fired is a `needs_review` reason cleared by an answer at the head (answers arrive with `add-change-request-review`). `reasons` MUST list every rule that fired, cleared or not, ordered by outcome precedence, then `rule`, then `subject`.

#### Scenario: Pending outranks blocked
- **WHEN** required workflow `ci` failed on the head and required workflow `e2e` has no run on it
- **THEN** the verdict is `pending` and `reasons` holds a `required_workflow_missing` reason for `e2e` and a `required_workflow_failed` reason for `ci`

#### Scenario: Blocked outranks needs_review
- **WHEN** required workflow `ci` failed and the claims have `door` `one_way` under a `needs_review` setting
- **THEN** the verdict is `blocked` and `reasons` includes the `one_way_door` reason

### Requirement: Verdict reasons are stable
Each reason MUST have a `rule` from a stable set, the `outcome` it contributes, a `subject`, and a human-readable `message`. The same inputs and policy version MUST produce the same reasons. Phase 1 rules are `git_facts_missing`, `claims_missing`, `required_workflow_missing`, `required_workflow_failed`, `one_way_door`, `proof_below_minimum`, `open_items`, `path_match`, `max_changed_files` and `max_changed_lines`; later phases add rules to this set.

#### Scenario: Recomputing without changes
- **WHEN** a verdict is recomputed with the same facts, claims, workflow runs and policy version
- **THEN** its `state` and `reasons` are unchanged

### Requirement: Reason subjects identify the reason
A reason's `subject` SHALL be an array of strings, sorted unless its rule defines an order. Two reasons of one verdict MUST NOT share both `rule` and `subject`, so `rule` plus `subject` identifies a reason. Numbers in a subject, such as a change request number, MUST be written as decimal strings.

#### Scenario: Two policy entries match the same file
- **WHEN** `paths` entries `app/priv/**` and `app/priv/repo/**` both match `app/priv/repo/a.exs`
- **THEN** the verdict has two `path_match` reasons with subjects `["app/priv/**", "app/priv/repo/a.exs"]` and `["app/priv/repo/**", "app/priv/repo/a.exs"]`

### Requirement: The verdict covers only the last reported head
The verdict MUST be computed for the change request's current head only. Inputs for other heads, including claims and workflow runs on earlier heads, MUST NOT affect it. The one exception is a verify run on an earlier commit that counts for the head under the verify-runs rule for when a run counts for a change request.

#### Scenario: Workflow passed on an earlier head
- **WHEN** `ci` passed on `H1`, the head is now `H2`, and `ci` has no run on `H2`
- **THEN** the verdict is `pending` with a `required_workflow_missing` reason whose `subject` is `["ci"]`

#### Scenario: Verify run before a docs-only commit
- **WHEN** a final clean verify run graded the approved intent digest on `H1`, and the head is now `H2`, whose only commit after `H1` changes paths matching `evidence.ignore_paths`
- **THEN** the run counts for the verdict at `H2`

### Requirement: Missing facts or claims make the verdict pending
With no Git facts for its current head and `target_branch`, the verdict MUST be `pending` with a `git_facts_missing` reason, and no rule that reads Git facts or claims runs. With no report ever made, `subject` is `[]` and the verdict's `head` null; otherwise (after a retarget, see `add-change-request-merge`) `subject` is `[<head>]` and `head` is kept. With Git facts and no claims for the head, it MUST get `claims_missing` (`pending`, `subject` `[<head>]`) and the claims rules MUST NOT run.

#### Scenario: New change request
- **WHEN** a change request has just been created
- **THEN** its verdict is `pending` with `head` null and one `git_facts_missing` reason

#### Scenario: Facts without claims
- **WHEN** a change request has Git facts for `H` and no claims for `H`
- **THEN** the verdict is `pending` with a `claims_missing` reason

### Requirement: Required workflows gate the verdict
For each name in the policy's `evidence.required_workflows`, the server SHALL look at stored workflow runs of the project with that `workflow`, `source.commit` equal to the head, and `source.dirty` not true. With no such run, or a newest run (by `started_at`, then `run_id`) that is `cancelled`, it MUST add `required_workflow_missing` (`pending`). A newest run that `failed` MUST add `required_workflow_failed` (`blocked`).

#### Scenario: Required workflow passed
- **WHEN** `required_workflows` is `["ci"]` and the newest `ci` run on the head `passed`
- **THEN** no required-workflow reason is added

#### Scenario: Newest run failed
- **WHEN** `ci` passed on the head at 10:00 and failed on the head at 11:00
- **THEN** the verdict has a `required_workflow_failed` reason with `subject` `["ci"]` and is at least `blocked`

#### Scenario: Retry passed
- **WHEN** `ci` failed on the head at 10:00 and passed on the head at 11:00
- **THEN** no required-workflow reason is added

#### Scenario: Dirty run
- **WHEN** the only `ci` run on the head has `source.dirty` true
- **THEN** the verdict has a `required_workflow_missing` reason for `ci`

#### Scenario: No required workflows
- **WHEN** `required_workflows` is `[]`
- **THEN** no required-workflow reason is added

### Requirement: One-way doors follow the policy
When the claims have `door` `one_way` and `claims.one_way_door` is `needs_review` or `blocked`, the verdict MUST get a `one_way_door` reason with that outcome and `subject` `[]`. With `ignore`, or with `door` `two_way`, no reason is added.

#### Scenario: One-way door needs review
- **WHEN** the claims have `door` `one_way` and `claims.one_way_door` is `needs_review`
- **THEN** the verdict has a `one_way_door` reason with outcome `needs_review`

#### Scenario: Two-way door
- **WHEN** the claims have `door` `two_way`
- **THEN** no `one_way_door` reason is added

### Requirement: Proof below the minimum needs review
Proof levels are ordered `stated` < `pointed` < `walked` < `ran`. When any `safe_because` entry has a `proof` below `claims.min_proof_level`, the verdict MUST get one `proof_below_minimum` reason (`needs_review`) whose `subject` lists those entries' `fact` values.

#### Scenario: Pointed under a ran minimum
- **WHEN** `min_proof_level` is `ran` and the claims have one `safe_because` entry with `proof` `pointed` and fact `Cache keys are per project`
- **THEN** the verdict has a `proof_below_minimum` reason with `subject` `["Cache keys are per project"]`

#### Scenario: Every proof at the minimum
- **WHEN** `min_proof_level` is `walked` and every entry's `proof` is `walked` or `ran`
- **THEN** no `proof_below_minimum` reason is added

### Requirement: Open items follow the policy
When the claims' `left_open` or `questions` is not empty and `claims.open_items` is `needs_review` or `blocked`, the verdict MUST get one `open_items` reason with that outcome whose `subject` lists each `left_open[].risk` and each `questions[].id`. With `ignore`, no reason is added.

#### Scenario: One open question
- **WHEN** the claims have `questions` with id `q1`, `left_open` `[]`, and `claims.open_items` is `needs_review`
- **THEN** the verdict has an `open_items` reason with outcome `needs_review` and `subject` `["q1"]`

#### Scenario: Nothing open
- **WHEN** `left_open` and `questions` are both `[]`
- **THEN** no `open_items` reason is added

### Requirement: Sensitive paths follow their policy entry
For each policy `paths` entry whose `glob` matches the `path` or `old_path` of any `diff.files` entry of the head, the verdict MUST get one `path_match` reason with that entry's outcome, `subject` the entry's `glob` followed by the matched diff paths in sorted order, and a message naming the glob. An entry with outcome `ignore` adds no reason.

#### Scenario: Migration touched
- **WHEN** a `paths` entry has `glob` `app/priv/repo/migrations/**` and `outcome` `needs_review`, and the diff adds `app/priv/repo/migrations/20261121_add_cr.exs`
- **THEN** the verdict has a `path_match` reason with outcome `needs_review` and that path in `subject`

#### Scenario: Renamed out of a sensitive directory
- **WHEN** the same entry exists and the diff renames `app/priv/repo/migrations/a.exs` to `app/priv/a.exs`
- **THEN** the verdict has a `path_match` reason for that entry

#### Scenario: Blocked path
- **WHEN** a `paths` entry has `glob` `.github/workflows/*` and `outcome` `blocked`, and the diff modifies `.github/workflows/ci.yml`
- **THEN** the verdict is at least `blocked`

### Requirement: Oversized diffs need review
When the head's `diff.files` has more entries than `size.max_changed_files`, the verdict MUST get a `max_changed_files` reason (`needs_review`). When the sum of `additions` and `deletions` over `diff.files` exceeds `size.max_changed_lines`, it MUST get a `max_changed_lines` reason (`needs_review`). Both have `subject` `[]`.

#### Scenario: Too many files
- **WHEN** `max_changed_files` is `40` and the diff has 41 files
- **THEN** the verdict has a `max_changed_files` reason with outcome `needs_review`

#### Scenario: At the line limit
- **WHEN** `max_changed_lines` is `1500` and the diff has 1,000 additions and 500 deletions
- **THEN** no `max_changed_lines` reason is added

### Requirement: Verdicts are recomputed when an input changes
A `draft` or `open` change request's verdict MUST be recomputed in the transaction that accepts a Git facts report that sets the head, a claims upload, a state change, or a workflow run whose `source.commit` is its head. A new policy version MUST recompute every `draft` and `open` change request of the project, in that transaction up to a configured count (default 100) and otherwise in a background job. `closed` and `merged` verdicts MUST NOT be recomputed.

#### Scenario: Workflow run on the head
- **WHEN** a change request's verdict is `pending` only because `ci` has no run on head `H`, and a passed `ci` run with `source.commit` `H` is uploaded
- **THEN** a show right after the upload returns the recomputed verdict without that reason

#### Scenario: New policy version
- **WHEN** an admin writes a policy version that sets `claims.one_way_door` to `ignore`
- **THEN** each `open` change request whose only reason was `one_way_door` now has verdict `mergeable` and `policy_version` equal to the new version

#### Scenario: Closed change request
- **WHEN** a `closed` change request's head gets a new workflow run
- **THEN** its verdict is unchanged

#### Scenario: Reopen recomputes
- **WHEN** a policy version is written while a change request is `closed`, and it is then reopened
- **THEN** its verdict names the new policy version

### Requirement: Read the verdict
`GET .../change-requests/:number/verdict` SHALL return the stored verdict with `state`, `head`, `policy_version`, `reasons`, `inputs` and `computed_at`, so a client can check that the head and policy version are still current before acting.

#### Scenario: Read with a public key
- **WHEN** a client with a `pk_` key reads the verdict
- **THEN** the API responds `200` with `head` and `policy_version`

### Requirement: Change request routes are in the OpenAPI document
Every change request route SHALL be described in the OpenAPI document served at `/api/v1/openapi`, with its request body, its success responses, and each error status it can return (`400`, `401`, `403`, `404`, `406`, `409`, `413`, `415` and `422` where they apply). The claims upload MUST be described with a `text/markdown` request body.

#### Scenario: Spec lists the routes
- **WHEN** a client fetches `/api/v1/openapi`
- **THEN** it describes create, list, show, `ready`, `draft`, `close`, `reopen`, `merged`, Git facts report and read, claims upload and read, and verdict read, each with `409` where a conflict can occur

### Requirement: Grading policy settings take effect
From this phase the verdict SHALL apply the review policy's `scenarios`, `evidence.ignore_paths` and `coverage` settings, which `active_settings` lists as the review-policy capability requires. Each rule below MUST add one reason per subject with a stable `rule`, a `subject` (an array of strings, in the order given) and a message, and combine by the phase-1 precedence `pending > blocked > needs_review > mergeable`.

#### Scenario: Settings reported active
- **WHEN** a client reads the project's review policy
- **THEN** the active settings include `scenarios.require_approved_intent`, `scenarios.should_failures`, `scenarios.spec_gaps`, `scenarios.approver`, `evidence.ignore_paths`, `coverage.unmapped_areas` and `coverage.undriven_features`

### Requirement: An approved intent set is required
With `scenarios.require_approved_intent` true and a linked OpenSpec change, the verdict MUST be `pending` with reason `scenario_set_approval` while the change request has no intent set or its current intent version's digest is not approved (its latest decision is not `approve`). The reason's `subject` MUST be `[<current digest>]`, or `[]` when no intent set exists.

#### Scenario: No intent set yet
- **WHEN** change request 42 links `add-export`, has no intent set, and the policy requires an approved intent set
- **THEN** the verdict is `pending` with a `scenario_set_approval` reason whose `subject` is `[]`

#### Scenario: Unapproved edit
- **WHEN** digest `d1` was approved and version 2 with digest `d2` is uploaded
- **THEN** the verdict is `pending` with a `scenario_set_approval` reason with `subject` `["d2"]`

#### Scenario: Rejected digest
- **WHEN** digest `d2` is current and its latest decision is a rejection
- **THEN** the verdict is `pending` with a `scenario_set_approval` reason with `subject` `["d2"]`

#### Scenario: Default policy
- **WHEN** a project on policy version 0 has a change request linking `add-export` with no intent set
- **THEN** no `scenario_set_approval` reason is added

#### Scenario: Approval not required
- **WHEN** `require_approved_intent` is false and the current intent version is unapproved
- **THEN** no `scenario_set_approval` reason is added and the intent set's results are graded

### Requirement: Set approval is graded before Git facts
Before any Git facts are reported for the change request's current head, the `scenario_set_approval` and `scenario_set_missing` rules SHALL still run, since they read no Git facts, so a person can approve the intent set before code exists. Every other grading rule reads the head and MUST NOT run while `git_facts_missing` fires.

#### Scenario: Intent set uploaded before code
- **WHEN** change request 42 links `add-export`, has no Git facts, the policy requires an approved intent set, and its current intent version has unapproved digest `d1`
- **THEN** the verdict is `pending` with head null and exactly two reasons: `git_facts_missing` with `subject` `[]` and `scenario_set_approval` with `subject` `["d1"]`

#### Scenario: Approved before code
- **WHEN** digest `d1` of change request 42 is approved and no Git facts are reported
- **THEN** the verdict is `pending` with only the `git_facts_missing` reason

### Requirement: A change request without a linked change needs a scenario set
With `scenarios.require_approved_intent` true, a change request with no linked OpenSpec change MUST be `pending` with reason `scenario_set_missing` (`subject` `[]`) while it has no diff set. With `require_approved_intent` false, including policy version 0, no scenario set is required and `scenario_set_missing` MUST NOT fire.

#### Scenario: No change and no diff set
- **WHEN** change request 43 links no OpenSpec change, has no diff set, and the policy requires an approved intent set
- **THEN** the verdict is `pending` with a `scenario_set_missing` reason

#### Scenario: Nothing required
- **WHEN** `require_approved_intent` is false and change request 43 has no scenario set
- **THEN** no scenario reason is added

### Requirement: A diff-only change request needs review
With `scenarios.require_approved_intent` true, a change request that has a diff set and no intent set MUST get reason `diff_only_set` with outcome `needs_review` and `subject` `[]` at every head.

#### Scenario: Diff set only
- **WHEN** change request 43 links no OpenSpec change, has a diff set for its head, every Must passed, and the policy requires an approved intent set
- **THEN** the verdict has a `diff_only_set` reason and is at least `needs_review`

#### Scenario: New head keeps the reason
- **WHEN** a diff set is uploaded for a new head of change request 43
- **THEN** the recomputed verdict still has a `diff_only_set` reason

### Requirement: A diff set must name the head
A diff version names the head when its `revision` is the head or a prefix of it. When the current diff version does not name the change request's head, the verdict MUST be `pending` with reason `diff_set_revision` whose `subject` is `[<revision>]` as written, and that diff set MUST NOT be graded until a version naming the head is uploaded.

#### Scenario: Push after the diff set
- **WHEN** the diff set names `aaaa…` and the client reports `git-facts` for head `bbbb…`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason for `aaaa…`

#### Scenario: New diff set for the head
- **WHEN** a diff version naming `bbbb…` is uploaded
- **THEN** the `diff_set_revision` reason is gone

#### Scenario: Short SHA of the head
- **WHEN** the head is `bbbb123` followed by 33 more hex characters and the current diff version has `revision: bbbb123`
- **THEN** the verdict has no `diff_set_revision` reason and the diff set is graded

#### Scenario: Short SHA of another commit
- **WHEN** the head starts with `bbbb123` and the current diff version has `revision: aaaa123`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason whose `subject` is `["aaaa123"]`

### Requirement: Each graded set needs a counted run
A graded set is the approved current intent version (or the current intent version when approval is not required) and the current diff version naming the head. When no run counts for a graded set at the head, the verdict MUST be `pending` with reason `scenario_results_missing` whose `subject` is `[<source>]`.

#### Scenario: Approved but not graded
- **WHEN** the intent set is approved and no final clean run grades its digest at the head
- **THEN** the verdict is `pending` with a `scenario_results_missing` reason for `intent`

#### Scenario: Only a dirty run
- **WHEN** the only run grading the approved digest at the head has `dirty` true
- **THEN** the verdict is `pending` with a `scenario_results_missing` reason for `intent`

### Requirement: Must scenarios must pass
For each graded set, a `must` scenario whose result from the newest counted run is `failed` or `not_run` MUST add reason `must_failed` with outcome `blocked` and `subject` `[<source>, <scenario id>]`, so the same ID in the intent and diff sets gives two reasons.

#### Scenario: Must failed
- **WHEN** the newest counted run has `S1` (`must`) `failed`
- **THEN** the verdict is `blocked` with a `must_failed` reason for `S1`, unless a `pending` reason also fired

#### Scenario: Must not run
- **WHEN** the newest counted run has `S2` (`must`) `not_run`
- **THEN** the verdict has a `must_failed` reason for `S2` with outcome `blocked`

#### Scenario: Diff set Must fails
- **WHEN** the intent set's Musts all passed and the diff set's Must `D1` failed
- **THEN** the verdict is `blocked` with a `must_failed` reason for `D1`

### Requirement: Should failures follow the policy
For each graded set, a `should` scenario whose result from the newest counted run is `failed` MUST add reason `should_failed`, and one whose result is `not_run` MUST add reason `should_not_run`, both with `subject` `[<source>, <scenario id>]` and the outcome of `scenarios.should_failures` (`needs_review`, or no reason when `ignore`). `could` results MUST add no reason.

#### Scenario: Should failed
- **WHEN** `should_failures` is `needs_review` and `S4` (`should`) failed
- **THEN** the verdict has a `should_failed` reason for `S4` and is at least `needs_review`

#### Scenario: Should failures ignored
- **WHEN** `should_failures` is `ignore` and `S4` (`should`) failed
- **THEN** no `should_failed` reason is added

#### Scenario: Should not run
- **WHEN** `should_failures` is `needs_review` and the newest counted run has `S4` (`should`) `not_run`
- **THEN** the verdict has a `should_not_run` reason for `S4` and is at least `needs_review`

#### Scenario: Could failed
- **WHEN** `S5` (`could`) failed
- **THEN** no reason is added for `S5`

### Requirement: Spec gaps follow the policy
Each `coverage` row with `status` `no_check` in the graded intent version MUST add reason `spec_gap` with `subject` `[<capability>, <requirement>, <scenario>]` (in that order), with the outcome of `scenarios.spec_gaps` (`needs_review`, or no reason when `ignore`), unless the claims at the head close it.

#### Scenario: Spec gap reviewed
- **WHEN** `spec_gaps` is `needs_review`, the approved intent set has a `no_check` row for `exports` / `Export is audited` / `Audit entry written`, and no claim covers it
- **THEN** the verdict has a `spec_gap` reason with `subject` `["exports", "Export is audited", "Audit entry written"]`

#### Scenario: Default ignores spec gaps
- **WHEN** the project uses policy version 0 and the intent set has a `no_check` row
- **THEN** no `spec_gap` reason is added

### Requirement: A proven claim closes a spec gap
Spec gaps SHALL be evaluated against the claims at the head. A `no_check` row MUST NOT add `spec_gap` when a `safe_because` entry of those claims has `covers` equal to the row's `{capability, requirement, scenario}` and a `proof` at or above `claims.min_proof_level`. A covering entry below the minimum leaves the `spec_gap` reason in place, and `proof_below_minimum` fires as usual. A claims upload already recomputes the verdict.

#### Scenario: No claims at the head
- **WHEN** the head has no claims and the intent set has a `no_check` row
- **THEN** the verdict is `pending` with `claims_missing`, and the row is judged once claims for the head are uploaded

#### Scenario: Covered at the minimum
- **WHEN** `spec_gaps` is `needs_review`, `min_proof_level` is `ran`, and a `safe_because` entry with `proof` `ran` and evidence has `covers` `{capability: exports, requirement: "Export is audited", scenario: "Audit entry written"}` matching a `no_check` row
- **THEN** no `spec_gap` reason is added for that row

#### Scenario: Covered below the minimum
- **WHEN** the same row is covered by an entry with `proof` `walked` and `min_proof_level` is `ran`
- **THEN** the verdict has the `spec_gap` reason for that row and a `proof_below_minimum` reason naming the entry's `fact`

#### Scenario: Covers another scenario
- **WHEN** the only covering entry has `covers` with `scenario` `Audit entry removed` and the `no_check` row's `scenario` is `Audit entry written`
- **THEN** the verdict has the `spec_gap` reason for that row

### Requirement: Unmapped changed areas follow the policy
Each changed file of the head that is an unmapped area in the current feature index MUST add reason `unmapped_area` with `subject` `[<path>]`, with the outcome of `coverage.unmapped_areas` (`needs_review`, `blocked`, or no reason when `ignore`).

#### Scenario: New directory
- **WHEN** `unmapped_areas` is `needs_review` and the head changes `app/lib/good_flows/new_thing.ex`, which no feature maps
- **THEN** the verdict has an `unmapped_area` reason for that path

### Requirement: Changed features must be driven
Each feature that a changed file maps to and that is undriven at the head MUST add reason `undriven_feature` with `subject` `[<feature id>]`, with the outcome of `coverage.undriven_features` (`needs_review`, `blocked`, or no reason when `ignore`).

#### Scenario: Feature not driven
- **WHEN** `undriven_features` is `blocked`, the head changes a file of `checkout`, and no counted run lists `checkout` `passed`
- **THEN** the verdict is `blocked` with an `undriven_feature` reason for `checkout`, unless a `pending` reason also fired

#### Scenario: Feature driven
- **WHEN** a counted run lists `{id: "checkout", result: "passed"}`
- **THEN** no `undriven_feature` reason is added for `checkout`

### Requirement: Coverage needs a feature index
When the project has never synced a feature index and `coverage.unmapped_areas` or `coverage.undriven_features` is not `ignore`, the verdict MUST be `pending` with one reason `feature_index_missing` (`subject` `[]`) in place of both coverage rules. When both are `ignore`, as in policy version 0, no coverage reason is added.

#### Scenario: No index
- **WHEN** the project has no feature index and `undriven_features` is `blocked`
- **THEN** the verdict is `pending` with one `feature_index_missing` reason and no `unmapped_area` or `undriven_feature` reasons

#### Scenario: Coverage off
- **WHEN** the project has no feature index and both coverage settings are `ignore`
- **THEN** no `feature_index_missing` reason is added

### Requirement: Verdict includes scenario results
The verdict response SHALL include `scenarios` with, per set (`intent`, `diff`), `version`, `digest`, `approved`, `graded`, and per scenario `id`, `priority`, `result` and the `run_id` it came from; `coverage` with the feature index `version`, `unmapped_areas` and per mapped feature `id` and `driven`; and `counted_runs`. The stored verdict MUST record the approved digest, counted run IDs and index version among its input digests.

#### Scenario: Results in the verdict
- **WHEN** a counted run R2 has `S1` `passed`
- **THEN** the verdict's `scenarios.intent` lists `{id: "S1", priority: "must", result: "passed", run_id: R2}` and `counted_runs` contains R2

#### Scenario: Public key reads coverage
- **WHEN** a `pk_` key reads the verdict
- **THEN** scenario IDs, priorities, results, counts and `coverage.version` are shown, `coverage.unmapped_areas` is null, each mapped feature has `id` null and `driven` as computed, and no `reason`, `failed_step`, thread link or artifact URL is present

#### Scenario: Private key reads coverage
- **WHEN** an `sk_` key reads the same verdict
- **THEN** `coverage.unmapped_areas` lists the unmapped paths and each mapped feature has its `id`

### Requirement: Grading inputs recompute the verdict
The verdict of every `draft` or `open` change request affected SHALL be recomputed in the transaction that uploads a scenario set version or records an approval or rejection on it, or makes a verify run `final` whose digest is one of its current set digests. A transaction that creates a feature index version MUST recompute every `draft` and `open` change request of its project, in that transaction up to a configured count (default 100) and otherwise in a background job.

#### Scenario: Run commit recomputes
- **WHEN** a verify run grading change request 42's approved digest at its head becomes `final`
- **THEN** the verdict of change request 42 read right after the commit uses that run

#### Scenario: Approval recomputes
- **WHEN** a client approves the current intent digest of change request 42
- **THEN** the verdict read right after has no `scenario_set_approval` reason

### Requirement: Change requests record the runs they counted
Each change request SHALL keep the set of verify runs that counted in any verdict computed for it, including verdicts for earlier heads, so artifact retention can tell when every change request that counted a run is `merged` or `closed`.

#### Scenario: Run counted at an earlier head
- **WHEN** run R counted for change request 42 at head A, and a later head B no longer counts it
- **THEN** R stays recorded as counted by change request 42
