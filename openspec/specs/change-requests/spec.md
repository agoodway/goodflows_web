# change-requests Specification

## Purpose

Stores change requests, the records that replace pull requests: their lifecycle, the Git facts and claims a client reports for each head, and the verdict the server computes from those facts and the project's review policy so clients know whether a person needs to look.

## Requirements

### Requirement: Change request routes require a key of the account
Every route under `/api/v1/projects/:project/change-requests` SHALL require a valid API key for the project's account. Missing, expired or revoked keys MUST return `401`. `ck_` keys MUST return `403` on every route. `pk_` keys MUST be allowed, with redaction, on `GET` routes except `.../review` and `.../tasks` (`sk_` only), and MUST return `403` on every other route. An invalid project slug returns `422` on `project`; an unknown slug returns `404`.

#### Scenario: Private key opens a change request
- **WHEN** a client with an `sk_` key posts a valid change request to project `goodcases` of its account
- **THEN** the API responds `201`

#### Scenario: Public key reads
- **WHEN** a client with a `pk_` key lists the change requests of project `goodcases`
- **THEN** the API responds `200`

#### Scenario: Public key cannot write
- **WHEN** a client with a `pk_` key creates a change request, reports Git facts, uploads claims, or changes a state
- **THEN** the API responds `403`, does not read the body, and stores nothing

#### Scenario: Public key and review routes
- **WHEN** a client with a `pk_` key reads `.../change-requests/1/review` or `.../change-requests/1/tasks`
- **THEN** the API responds `403`

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
A change request response MUST include under `data` the `id`, `number`, `title`, `state`, `source_branch`, `target_branch`, `openspec_change` (or null), `links` (or null), `head` (the last reported head, or null), `parent` (the parent change request's number, or null), `dependencies` (the stored change ids, `[]` when none), `opened_by` with the opener's `user_id`, `merge` (null unless merged), `inserted_at` and `updated_at`. It MUST NOT include `account_id` or `project_id`.

#### Scenario: New change request
- **WHEN** a client creates a change request without Git facts
- **THEN** the response has `head` null, `parent` null, `dependencies` `[]`, `merge` null, and `opened_by.user_id` equal to the key owner's user id

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
`POST .../change-requests/:number/merged` SHALL accept only `merged_commit` (40 or 64 lowercase hex characters) and `target_branch` (1 to 256 UTF-8 bytes, no control characters), both required, and an optional `lease_id` (a string; one that names no active lease of the change request is recorded as a merge without a lease, and a non-string MUST return `422` on `lease_id`). It is accepted from `draft` or `open` and moves the change request to `merged`.

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

#### Scenario: Non-string lease ID
- **WHEN** a client reports a merge with `lease_id` `42`
- **THEN** the API responds `422` with an error on `lease_id` and the state is unchanged

### Requirement: The merge record keeps the verdict at merge
The response's `merge` MUST hold `merged_commit`, `target_branch`, `merged_at`, the `head`, the `verdict_state`, `policy_version` and `reasons` of the verdict at that head, `merged_without_mergeable_verdict`, `merged_without_lease`, `head_count` and `fix_iterations`. `head_count` and `fix_iterations` MUST be null for a merge recorded before they existed. These values MUST NOT change after the merge is recorded.

#### Scenario: Verdict stored with the merge
- **WHEN** an `open` change request whose verdict at head `H` is `needs_review` under policy version `4` with one `one_way_door` reason is reported merged
- **THEN** `merge` has `head` `H`, `verdict_state` `needs_review`, `policy_version` `4`, and `reasons` with that `one_way_door` reason

#### Scenario: Merge record after a policy change
- **WHEN** a change request was merged under policy version `4` and an admin then writes version `5`
- **THEN** its `merge.policy_version` is still `4` and `merge.reasons` are unchanged

#### Scenario: Merge recorded before the counts existed
- **WHEN** a client shows a change request merged before `head_count` and `fix_iterations` were added
- **THEN** `merge.head_count` and `merge.fix_iterations` are null

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
A change request's verdict SHALL have `state` `pending` (an input is missing at the head), `blocked` (an input fails), `needs_review` (rules fired that need a person) or `mergeable` (no rule fired, or every reason is a `needs_review` reason cleared by answers at the head). It MUST carry the `head` (or null), the `policy_version`, `reasons`, the input digests under `inputs`, and `computed_at`. A verdict is computed in `draft` and `open`.

#### Scenario: Nothing fired
- **WHEN** a change request has Git facts and claims for head `H`, every required workflow passed on `H`, and no rule fires
- **THEN** the verdict is `mergeable` with `reasons` `[]`, `head` `H`, and the project's current policy version

#### Scenario: Verdict on a draft
- **WHEN** a `draft` change request gets Git facts and claims
- **THEN** its verdict is computed and is not `pending` because of the state

### Requirement: The verdict takes the highest-precedence outcome
The verdict `state` MUST be the highest-precedence outcome of all rules that fired, with precedence `pending`, then `blocked`, then `needs_review`, and `mergeable` when no rule fired or every reason that fired is a `needs_review` reason cleared by answers at the head. `reasons` MUST list every rule that fired, cleared or not, ordered by outcome precedence, then `rule`, then `subject`.

#### Scenario: Pending outranks blocked
- **WHEN** required workflow `ci` failed on the head and required workflow `e2e` has no run on it
- **THEN** the verdict is `pending` and `reasons` holds a `required_workflow_missing` reason for `e2e` and a `required_workflow_failed` reason for `ci`

#### Scenario: Blocked outranks needs_review
- **WHEN** required workflow `ci` failed and the claims have `door` `one_way` under a `needs_review` setting
- **THEN** the verdict is `blocked` and `reasons` includes the `one_way_door` reason

#### Scenario: Open items split into several items
- **WHEN** the only reason is `open_items` with 2 claims questions, and one question is answered `choose` at the head
- **THEN** the verdict stays `needs_review` until the other question is answered `choose`

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
The verdict MUST be computed for the change request's current head only. Inputs for other heads, including claims and workflow runs on earlier heads, MUST NOT affect it. There are two exceptions: a verify run on an earlier commit that counts for the head under the verify-runs rule for when a run counts for a change request, and a merge-result verify run that decides the merge-result check of the `merge-coordination` capability.

#### Scenario: Workflow passed on an earlier head
- **WHEN** `ci` passed on `H1`, the head is now `H2`, and `ci` has no run on `H2`
- **THEN** the verdict is `pending` with a `required_workflow_missing` reason whose `subject` is `["ci"]`

#### Scenario: Verify run before a docs-only commit
- **WHEN** a final clean verify run graded the approved intent digest on `H1`, and the head is now `H2`, whose only commit after `H1` changes paths matching `evidence.ignore_paths`
- **THEN** the run counts for the verdict at `H2`

#### Scenario: Merge-result run on a merge commit
- **WHEN** CR 42 at head `H` holds a lease with `base` `B`, regrading applies, and a final clean run with `merge_result` `{base: B, commit: M}` and `source.commit` `M` passes every Must of the approved intent set
- **THEN** the merge-result check passes, although `M` is not `H`

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
- **THEN** the active settings include `scenarios.require_approved_intent`, `scenarios.should_failures`, `scenarios.spec_gaps`, `scenarios.approver`, `scenarios.diff_only`, `evidence.ignore_paths`, `coverage.unmapped_areas` and `coverage.undriven_features`

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
With `scenarios.require_approved_intent` true and `scenarios.diff_only` `needs_review`, a change request that has a diff set and no intent set MUST get reason `diff_only_set` with outcome `needs_review` and `subject` `[]` at every head. With `scenarios.diff_only` `weakening` or `ignore`, `diff_only_set` MUST NOT fire.

#### Scenario: Diff set only
- **WHEN** change request 43 links no OpenSpec change, has a diff set for its head, every Must passed, the policy requires an approved intent set, and `scenarios.diff_only` is `needs_review`
- **THEN** the verdict has a `diff_only_set` reason and is at least `needs_review`

#### Scenario: New head keeps the reason
- **WHEN** `scenarios.diff_only` is `needs_review` and a diff set is uploaded for a new head of change request 43
- **THEN** the recomputed verdict still has a `diff_only_set` reason

#### Scenario: Diff-only ignored
- **WHEN** change request 43 links no OpenSpec change, has a diff set naming its head, a counted run passed every scenario, the policy requires an approved intent set, and `scenarios.diff_only` is `ignore`
- **THEN** the verdict has no `diff_only_set` reason and no scenario reason holds it from `mergeable`

#### Scenario: Weakening mode has no per-head reason
- **WHEN** `scenarios.diff_only` is `weakening` and the current diff version of change request 43 drops no Must of its baseline
- **THEN** the verdict has no `diff_only_set` and no `diff_set_weakened` reason

### Requirement: A diff set must name the head
A diff version names head H when its `revision` is H or a prefix of it. Otherwise it names H when it is a prefix of exactly one commit in H's `git-facts.commits` and every later commit's changed files match `evidence.ignore_paths`. When the current diff version does not name the head, the verdict MUST be `pending` with reason `diff_set_revision` whose `subject` is `[<revision>]` as written, and that diff set MUST NOT be graded.

#### Scenario: Push after the diff set
- **WHEN** the diff set names `aaaa…` and the client reports `git-facts` for head `bbbb…`, whose commit after `aaaa…` changes `app/lib/good_flows/caches.ex`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason for `aaaa…`

#### Scenario: New diff set for the head
- **WHEN** a diff version naming `bbbb…` is uploaded
- **THEN** the `diff_set_revision` reason is gone

#### Scenario: Short SHA of the head
- **WHEN** the head is `bbbb123` followed by 33 more hex characters and the current diff version has `revision: bbbb123`
- **THEN** the verdict has no `diff_set_revision` reason and the diff set is graded

#### Scenario: Short SHA of another commit
- **WHEN** the head starts with `bbbb123`, the current diff version has `revision: aaaa123`, and no commit in the head's `git-facts.commits` starts with `aaaa123`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason whose `subject` is `["aaaa123"]`

#### Scenario: Docs-only push after the diff set
- **WHEN** the current diff version has `revision` `aaaa123`, commit `aaaa123…` is in head H's `git-facts.commits`, the only later commit changes `docs/usage.md`, and `ignore_paths` is `["docs/**"]`
- **THEN** the verdict has no `diff_set_revision` reason and the diff set is graded at H

#### Scenario: Commit not in the facts
- **WHEN** the current diff version names a commit from before a rebase that is not in H's `git-facts.commits` and is not a prefix of H
- **THEN** the verdict is `pending` with a `diff_set_revision` reason

#### Scenario: Ambiguous short SHA
- **WHEN** the current diff version has `revision` `aaaa123`, H does not start with `aaaa123`, and two earlier commits in H's `git-facts.commits` start with `aaaa123`
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
The verdict response SHALL include `scenarios` with, per set (`intent`, `diff`), `version`, `digest`, `approved`, `graded`, and per scenario `id`, `priority`, `result` and the `run_id` it came from; the diff set also has `accepted` and `baseline_version`; `coverage` with the feature index `version`, `unmapped_areas` and per mapped feature `id` and `driven`; and `counted_runs`. The stored verdict MUST record the approved digest, the diff baseline digest, counted run IDs and index version among its input digests.

#### Scenario: Results in the verdict
- **WHEN** a counted run R2 has `S1` `passed`
- **THEN** the verdict's `scenarios.intent` lists `{id: "S1", priority: "must", result: "passed", run_id: R2}` and `counted_runs` contains R2

#### Scenario: Diff baseline in the verdict
- **WHEN** diff version 2 was accepted and version 4 is current and unaccepted
- **THEN** the verdict's `scenarios.diff` has `version` 4, `accepted` false and `baseline_version` 2

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

### Requirement: Answers resolve needs_review
A verdict whose highest-precedence outcome is `needs_review` SHALL become `mergeable` when every review packet item at the current head has a current answer of `approve` or `choose`. A reason is cleared when every item made from it is, so an `open_items` reason needs all of its `question` and `open_item` items. An item whose current answer is `request_change` or `reject`, or that has no answer, MUST keep the verdict at `needs_review`. The reasons MUST stay in the verdict after they are cleared, except `diff_set_weakened` reasons, which are gone once the answers accept the diff digest and make it the baseline.

#### Scenario: All items approved
- **WHEN** change request 42 has `one_way_door` and `size` items at head `a1b2c3d…`, and both are answered `approve` at that head
- **THEN** the verdict at `a1b2c3d…` is `mergeable` and still lists both reasons

#### Scenario: One item asks for a change
- **WHEN** one of two items is answered `approve` and the other `request_change`
- **THEN** the verdict stays `needs_review`

#### Scenario: Question answered by choose
- **WHEN** the only item is a `question` answered `choose` with option `keep`
- **THEN** the verdict is `mergeable`

#### Scenario: Last approval
- **WHEN** the last open item is answered `approve`
- **THEN** the verdict read right after the `201` is `mergeable`

#### Scenario: Accepted weakening leaves the verdict
- **WHEN** the only item at head H is `diff_set_weakened` for `S3` and it is answered `approve`
- **THEN** the verdict read right after the `201` is `mergeable` and has no `diff_set_weakened` reason

### Requirement: Answers never override blocked or pending
Answers SHALL clear only `needs_review` items. A `scenario_set_approval` answer clears no item itself; it acts only through the scenario set decision it records. A verdict with any `blocked` reason MUST stay `blocked`, and one with any `pending` reason MUST stay `pending`, whatever answers exist. Answers given while the verdict is `blocked` or `pending` SHALL be stored and SHALL count once those reasons are gone at the same head.

#### Scenario: Blocked with every item approved
- **WHEN** a Must scenario failed at the head and every item is answered `approve`
- **THEN** the verdict is `blocked`

#### Scenario: Pending clears at the same head
- **WHEN** every item is approved while the `ci` run is missing, and then a passing `ci` run on the same head is stored
- **THEN** the verdict becomes `mergeable` without new answers

### Requirement: The verdict is recomputed on review input
The verdict SHALL be recomputed inside the transaction that stores an answer, replaces an answer, or records a scenario set approval or rejection through an answer.

#### Scenario: Last approval
- **WHEN** the last open item is answered `approve`
- **THEN** the verdict read right after the `201` is `mergeable`

### Requirement: The verdict reports review progress
The verdict response SHALL include `review` with `items` (the number of packet items at the head) and `cleared` (the number with a current `approve` or `choose` answer at the head). A `scenario_set_approval` item is counted in `items` but never in `cleared`: it is cleared only by the set's approval, which removes it from the packet.

#### Scenario: Progress counts
- **WHEN** a head has 3 items, 2 answered `approve` and 1 answered `request_change`
- **THEN** the verdict has `review` `{"items": 3, "cleared": 2}`

#### Scenario: New head resets progress
- **WHEN** a new head is reported with 3 items
- **THEN** the verdict has `review` `{"items": 3, "cleared": 0}`

### Requirement: A change request may name a parent

`PUT /api/v1/projects/:project/change-requests/:number/parent` with `{"number": <n>}` SHALL set the change request's one parent and respond `200` with the change request, which shows `parent`. `DELETE` on the same path SHALL clear it and respond `200`. Both require an `sk_` key of the account (`pk_` `403`) and a child in `draft` or `open` (else `409` `not_editable`).

#### Scenario: Set a parent

- **WHEN** CR 41 and CR 42 are `open` in project `goodcases` and a client puts `{"number": 41}` to CR 42's parent route
- **THEN** the API responds `200` with `parent: 41`

#### Scenario: Replace the parent

- **WHEN** CR 42's parent is 40 and a client puts `{"number": 41}`
- **THEN** CR 42's parent is 41 and it has no other parent

#### Scenario: Clear the parent

- **WHEN** CR 42's parent is 41 and a client deletes CR 42's parent
- **THEN** the API responds `200` with `parent: null`

#### Scenario: Merged child

- **WHEN** CR 42 is `merged` and a client puts `{"number": 41}` to its parent route
- **THEN** the API responds `409` with `error: "not_editable"` and the parent is unchanged

### Requirement: A parent has a lower number in the same project

A parent SHALL be a change request of the same project with a lower number than the child. A number that names no change request of the project, or a number equal to or higher than the child's, MUST return `422` on `number`. This rule makes parent chains acyclic.

#### Scenario: Higher number

- **WHEN** a client puts `{"number": 43}` to CR 42's parent route
- **THEN** the API responds `422` with an error on `number` and the parent is unchanged

#### Scenario: Self as parent

- **WHEN** a client puts `{"number": 42}` to CR 42's parent route
- **THEN** the API responds `422` with an error on `number`

#### Scenario: Unknown number

- **WHEN** a client puts `{"number": 7}` to CR 42's parent route and project `goodcases` has no CR 7
- **THEN** the API responds `422` with an error on `number`

### Requirement: A child waits for its parent to merge

While a change request's parent is `draft` or `open`, its verdict SHALL be `pending` with a reason whose `rule` is `parent_not_merged` and whose `subject` is `[<parent number>]`. The child is still graded and reviewed, and its other reasons are kept. When the parent becomes `merged` the reason MUST be removed and the child's verdict recomputed.

#### Scenario: Parent open

- **WHEN** CR 42's parent CR 41 is `open` and CR 42's other rules would make it `mergeable`
- **THEN** CR 42's verdict is `pending` with reason `parent_not_merged` and subject `["41"]`

#### Scenario: Other reasons kept

- **WHEN** CR 42's parent is `open` and a `path_match` rule fired on CR 42
- **THEN** CR 42's verdict lists both `parent_not_merged` and the `path_match` reason

#### Scenario: Parent merges

- **WHEN** CR 41 is reported merged
- **THEN** CR 42's verdict is recomputed in the same transaction without `parent_not_merged`

### Requirement: A closed parent holds the child pending

While a change request's parent is `closed`, its verdict SHALL be `pending` with a reason whose `rule` is `parent_closed` and whose `subject` is `[<parent number>]`. Reopening the parent MUST replace it with `parent_not_merged`; clearing the parent MUST remove it.

#### Scenario: Parent closed

- **WHEN** CR 41 is closed while it is CR 42's parent
- **THEN** CR 42's verdict is `pending` with reason `parent_closed` and subject `["41"]`

#### Scenario: Parent reopened

- **WHEN** CR 41 is reopened to `open`
- **THEN** CR 42's verdict has reason `parent_not_merged` and no `parent_closed`

#### Scenario: Parent cleared

- **WHEN** CR 42's parent CR 41 is closed and a client deletes CR 42's parent
- **THEN** CR 42's verdict has neither `parent_closed` nor `parent_not_merged`

### Requirement: A change request may list the changes it depends on

`PUT /api/v1/projects/:project/change-requests/:number/dependencies` with `{"change_ids": [...]}` SHALL replace the change request's `dependencies` with the given list, in the given order, recompute its verdict in the same transaction, and respond `200` with the change request. An empty list clears it. It requires an `sk_` key of the account (`pk_` and `ck_` `403`) and a change request in `draft` or `open` (else `409` `not_editable`, nothing changed).

#### Scenario: Set dependencies

- **WHEN** CR 42 is `open` and a client puts `{"change_ids": ["add-login", "add-sessions"]}` to its dependencies route
- **THEN** the API responds `200` with `dependencies` `["add-login", "add-sessions"]`, and the list and show responses carry the same list

#### Scenario: Replace and clear

- **WHEN** CR 42's dependencies are `["add-login"]` and a client puts `{"change_ids": ["add-sessions"]}`, then `{"change_ids": []}`
- **THEN** CR 42's dependencies are `["add-sessions"]`, then `[]`

#### Scenario: Merged change request

- **WHEN** CR 42 is `merged` and a client puts `{"change_ids": ["add-login"]}`
- **THEN** the API responds `409` with `error: "not_editable"` and the dependencies are unchanged

### Requirement: Dependency ids follow the change id rule

`change_ids` SHALL be an array of at most 50 distinct strings, each a 1 to 64 byte slug matching `[a-z0-9][a-z0-9-]*`, the rule of `openspec_change`. A body with another key, an id that breaks the rule, a duplicate id, or the change request's own `openspec_change` MUST return `422` on `change_ids` (an invalid entry on `change_ids[<index>]`) and change nothing.

#### Scenario: Invalid id

- **WHEN** a client puts `{"change_ids": ["Add_Login"]}`
- **THEN** the API responds `422` with an error on `change_ids` and the dependencies are unchanged

#### Scenario: Own change

- **WHEN** CR 42 links `add-login` and a client puts `{"change_ids": ["add-login"]}` to CR 42's dependencies route
- **THEN** the API responds `422` with an error on `change_ids`

#### Scenario: Duplicate id

- **WHEN** a client puts `{"change_ids": ["add-login", "add-login"]}`
- **THEN** the API responds `422` with an error on `change_ids`

### Requirement: A change request waits for its dependencies to merge

For each id in a `draft` or `open` change request's `dependencies` that no `merged` change request of the same project links as its `openspec_change`, the verdict SHALL be `pending` with a reason whose `rule` is `dependency_not_merged` and whose `subject` is `[<change id>]`. The reason fires whatever the Git facts, and the change request's other reasons are kept. Its `message` MUST say which case holds and name rebasing onto a commit where the change is archived as a way out: a change request linking the id is `draft` or `open` (naming its numbers), every change request linking it is `closed`, or none links it. The verdict's `inputs.dependencies` SHALL be the stored id list.

#### Scenario: Dependency's change request open

- **WHEN** CR 42 depends on `add-login`, CR 41 links `add-login` and is `open`, and CR 42's other rules would make it `mergeable`
- **THEN** CR 42's verdict is `pending` with reason `dependency_not_merged`, subject `["add-login"]`, and a message naming change request 41

#### Scenario: Every linking change request closed

- **WHEN** CR 42 depends on `add-login` and the only change request linking it, CR 41, is `closed`
- **THEN** CR 42's verdict has `dependency_not_merged` with subject `["add-login"]` and a message saying every change request linking it is closed

#### Scenario: No change request links the id

- **WHEN** CR 42 depends on `add-login` and no change request of the project links it
- **THEN** CR 42's verdict has `dependency_not_merged` with subject `["add-login"]` and a message saying none links it

#### Scenario: One merged linking change request satisfies the dependency

- **WHEN** CR 42 depends on `add-login`, CR 40 linking it is `closed` and CR 41 linking it is `merged`
- **THEN** CR 42's verdict has no `dependency_not_merged` reason

#### Scenario: Another project's change request

- **WHEN** CR 42 depends on `add-login` and only a change request of another project links `add-login`
- **THEN** CR 42's verdict has `dependency_not_merged` with subject `["add-login"]`

#### Scenario: One reason per unmerged id

- **WHEN** CR 42 depends on `add-login` and `add-sessions` and neither is linked by a merged change request
- **THEN** CR 42's verdict has two `dependency_not_merged` reasons, with subjects `["add-login"]` and `["add-sessions"]`, and `inputs.dependencies` `["add-login", "add-sessions"]`

### Requirement: A dependency's merge recomputes its dependents

When a change request that links a change id merges, closes, reopens, or moves between `draft` and `open`, or is created linking it, every `draft` or `open` change request of the project whose `dependencies` include that id SHALL get a recomputed verdict without a new Git facts report. The recompute MAY run after the transaction that made the change commits, and it MUST NOT be lost if that transaction commits. A dependencies update and a state change of a change request linking one of its ids MUST NOT both miss each other's change.

#### Scenario: Dependency merges

- **WHEN** CR 41 links `add-login`, CR 42 depends on `add-login` with an otherwise `mergeable` verdict, and CR 41's merge is reported
- **THEN** CR 42's verdict is recomputed to `mergeable` without CR 42 reporting new Git facts

#### Scenario: Dependent with a lower number

- **WHEN** CR 41 depends on `add-login` and CR 42, which links `add-login`, merges
- **THEN** CR 41's verdict is recomputed without `dependency_not_merged`

#### Scenario: Dependency closes

- **WHEN** CR 41 links `add-login`, CR 42 depends on it, and CR 41 is closed
- **THEN** CR 42's `dependency_not_merged` message says every change request linking `add-login` is closed

### Requirement: The dependencies route and rule are in the OpenAPI document

The OpenAPI document SHALL describe the dependencies `PUT` route with its `403`, `404`, `409` and `422` responses, the change request's `dependencies` field, and `dependency_not_merged` among the verdict reason rules.

#### Scenario: OpenAPI lists dependencies

- **WHEN** a client fetches the OpenAPI document
- **THEN** it has the dependencies route, the change request schema lists `dependencies`, and the reason rule enum includes `dependency_not_merged`

### Requirement: Retargeting a change request

`POST /api/v1/projects/:project/change-requests/:number/retarget` with `{"target_branch": "<name>"}` SHALL change the target branch of a `draft` or `open` change request and respond `200`. With a parent, only the parent's target branch is allowed (else `422` on `target_branch`) and only after the parent is `merged` (else `409` `parent_not_merged`). Without one, any branch is allowed. It requires an `sk_` key, changes no Git ref, and recomputes the verdict in the same transaction.

#### Scenario: Retarget after the parent merges

- **WHEN** CR 41 targeting `main` is `merged` and CR 42 targeting `a` with parent 41 is retargeted to `main`
- **THEN** the API responds `200` with `target_branch: "main"` and CR 42's head is unchanged

#### Scenario: Parent not merged

- **WHEN** CR 41 is `open` and a client retargets its child CR 42 to `main`
- **THEN** the API responds `409` with `error: "parent_not_merged"` and the target is unchanged

#### Scenario: Wrong branch for a child

- **WHEN** CR 41 targeting `main` is `merged` and a client retargets CR 42 to `develop`
- **THEN** the API responds `422` with an error on `target_branch`

#### Scenario: No parent

- **WHEN** CR 50 has no parent and targets `main`, and a client retargets it to `release/1.2`
- **THEN** the API responds `200` with `target_branch: "release/1.2"`

#### Scenario: Retarget while holding a merge lease

- **WHEN** CR 50 holds an active merge lease and a client retargets it
- **THEN** the API responds `409` with `error: "lease_held"` and the target is unchanged

### Requirement: A retarget whose parent link keeps changing is not editable

A retarget SHALL lock the parent before the child. When the parent link changes between reading the change request and locking it, the retarget MUST roll back and start again from a fresh read, at most three attempts in all. When the link changes under every attempt, the API SHALL respond `409` with `error: "not_editable"` and the target is unchanged.

#### Scenario: Parent set during a retarget

- **WHEN** CR 42 has a `merged` parent targeting `main`, a client retargets it to `main`, and its parent is changed to the `open` CR 43 before the retarget locks CR 42
- **THEN** the API responds `409` with `error: "parent_not_merged"` and the target is unchanged

#### Scenario: Parent changed under every attempt

- **WHEN** CR 42's parent changes before each of three attempts of a retarget locks CR 42
- **THEN** the API responds `409` with `error: "not_editable"` and the target is unchanged

### Requirement: A retarget admits new Git facts for the same head

After a retarget, the change request SHALL accept a `git-facts` report for its current head whose `target.branch` is the new target branch, under the core rule that reports are identified by head and target branch. Until it arrives, the verdict MUST be `pending` with a `git_facts_missing` reason whose `subject` is `[<head>]`, and the verdict and change request keep that `head`.

#### Scenario: New facts after retarget

- **WHEN** CR 42 at head `a1b2c3d` was retargeted from `a` to `main` and the client reports `git-facts` for `a1b2c3d` with `target.branch: "main"`
- **THEN** the API responds `201` and the verdict is computed from the new report

#### Scenario: Facts missing after retarget

- **WHEN** CR 42 at head `a1b2c3d` was retargeted to `main` and no `git-facts` for that head names `main`
- **THEN** CR 42's verdict is `pending` with a `git_facts_missing` reason with `subject` `["a1b2c3d…"]` and `head` `a1b2c3d…`

### Requirement: Answers survive a retarget at an unchanged head

A retarget SHALL NOT clear answers, scenario set approvals, or counted verify runs. Answers given at the head still count after a retarget for every review item that still exists at that head; items that are new from the new Git facts MUST need their own answers.

#### Scenario: Same items after retarget

- **WHEN** CR 42 at head `a1b2c3d` had its `one_way_door` item approved, is retargeted to `main`, and its new `git-facts` produce the same `one_way_door` item
- **THEN** that item is still approved and needs no new answer

#### Scenario: New item after retarget

- **WHEN** CR 42's new `git-facts` against `main` add a `size` reason that was not present before
- **THEN** the verdict is `needs_review` until the `size` item is answered at head `a1b2c3d`

### Requirement: A merge without a valid lease is flagged

A merge report that names no `lease_id`, or names one that is not the change request's active, unexpired lease, SHALL still be recorded, with `merge.merged_without_lease` true. A merge under a valid lease MUST have `merge.merged_without_lease` false. The flag is independent of `merge.merged_without_mergeable_verdict`.

#### Scenario: Merge after the lease expired

- **WHEN** CR 42's lease `L1` expired at `12:10:00Z` and the client reports CR 42 merged with `lease_id` `L1` at `12:12:00Z`
- **THEN** CR 42 is `merged` with `merge.merged_without_lease` true

#### Scenario: Merge with no lease

- **WHEN** a client reports CR 42 merged without `lease_id` and CR 42 never held a lease
- **THEN** CR 42 is `merged` with `merge.merged_without_lease` true

#### Scenario: Both flags

- **WHEN** a client reports CR 42 merged without a lease while its verdict is `pending` with `merge_result_ungraded`
- **THEN** CR 42 has `merge.merged_without_lease` true and `merge.merged_without_mergeable_verdict` true

#### Scenario: Retry names a lease

- **WHEN** CR 42 was merged without a lease and the same merge report is sent again with a `lease_id`
- **THEN** the API responds `200` and `merge.merged_without_lease` is still true

### Requirement: Parent and retarget routes are in the OpenAPI document

The OpenAPI document SHALL describe the parent `PUT` and `DELETE` routes, the retarget route, the change request's `parent` and `merge.merged_without_lease` fields, the merge report's optional `lease_id`, and the `403`, `404`, `409` and `422` responses of each new route.

#### Scenario: OpenAPI lists the merge report lease

- **WHEN** a client fetches the OpenAPI document
- **THEN** the merge report request schema lists an optional `lease_id` and the merge schema lists `merged_without_lease`

### Requirement: A diff set's baseline
A change request's diff baseline SHALL be the newest diff version whose digest is accepted (its latest decision is `approve`), or version 1 when none is.

#### Scenario: No accepted version
- **WHEN** the diff set has versions 1 to 3 and no decision
- **THEN** the baseline is version 1

#### Scenario: Accepted version
- **WHEN** diff version 2's digest is accepted and version 3 is current
- **THEN** the baseline is version 2

#### Scenario: Latest decision decides
- **WHEN** the stored decisions on version 2's digest are `approve` and then `reject`, and no other diff digest is accepted
- **THEN** the baseline is version 1

### Requirement: A weakened diff set needs review
With `scenarios.require_approved_intent` true, `scenarios.diff_only` `weakening`, a graded diff set, no linked OpenSpec change and no intent set, each Must scenario of the baseline that the current version removes, or demotes to `should` or `could`, MUST add reason `diff_set_weakened` with outcome `needs_review` and `subject` `["diff", <id>]`. An edited section of a Must, with its priority kept, MUST NOT add a reason.

#### Scenario: Must demoted after a failure
- **WHEN** the baseline is version 1 with Must `S3`, and version 2, current and naming the head, has `S3` as `should`
- **THEN** the verdict has a `diff_set_weakened` reason with `subject` `["diff", "S3"]` and is at least `needs_review`

#### Scenario: Weakening kept on a later version
- **WHEN** version 2 demoted Must `S3`, no version was accepted, and version 3 keeps `S3` as `should`
- **THEN** the verdict at version 3 still has a `diff_set_weakened` reason for `S3`

#### Scenario: Renamed Must
- **WHEN** the baseline has Must `S3` and the current version has no `S3` but a new Must `S7`
- **THEN** the verdict has a `diff_set_weakened` reason for `S3`

#### Scenario: Edited Must
- **WHEN** the current version changes the section of Must `S3` and keeps it `must`
- **THEN** no `diff_set_weakened` reason is added

#### Scenario: Accepted weakening
- **WHEN** version 2, which demoted Must `S3`, was accepted, and version 3 for a new head keeps `S3` as `should`
- **THEN** the verdict at version 3 has no `diff_set_weakened` reason

#### Scenario: Diff set not graded
- **WHEN** the current diff version weakens its baseline and does not name the head
- **THEN** the verdict is `pending` with `diff_set_revision` and has no `diff_set_weakened` reason

#### Scenario: Linked change without an intent set
- **WHEN** change request 42 links `add-export`, has no intent set, and its current diff version weakens its baseline under `weakening`
- **THEN** the verdict is `pending` with `scenario_set_approval` and has no `diff_set_weakened` reason

### Requirement: A new Git facts report records its previous head and head kind

A Git facts report that stores a new row SHALL record `previous_head`, the change request's `head` before the report (null when it had none), and a `head_kind`: `first` when `previous_head` is null, `retarget` when it equals the reported head, and otherwise as the next two requirements say. An exact retry stores nothing and records no kind. `previous_head` and `head_kind` MUST NOT change after the row is stored.

#### Scenario: First head

- **WHEN** a client reports Git facts for head `H1` on a change request with no head
- **THEN** the stored report has `previous_head` null and `head_kind` `first`

### Requirement: A head that keeps the previous head is a fast-forward or a target merge

The previous head's merge base is that of its stored Git facts for the change request's `target_branch`, or else of its most recently stored ones. When `previous_head` is among the document's `commits`, `head_kind` MUST be `fast_forward` if `target.merge_base` equals the previous head's merge base, and `target_merged` otherwise.

#### Scenario: Fix commit on top

- **WHEN** Git facts for `H1` with merge base `B` are stored and a client reports `H2` whose `commits` include `H1`, with merge base `B`
- **THEN** the `H2` report has `previous_head` `H1` and `head_kind` `fast_forward`

#### Scenario: Target branch merged in

- **WHEN** Git facts for `H1` with merge base `B1` are stored and a client reports `H2` whose `commits` include `H1`, with merge base `B2`
- **THEN** the `H2` report has `head_kind` `target_merged`

### Requirement: A head that drops the previous head is a rebase or a rewrite

When `previous_head` is not among the document's `commits`, `head_kind` MUST be `rebase` if `target.merge_base` differs from the previous head's merge base and the document's commits, in order, have the same `changed_files` paths as the commits stored for `previous_head`. It MUST be `rewrite` otherwise, including when no Git facts are stored for `previous_head`.

#### Scenario: Clean rebase

- **WHEN** Git facts for `H1` with merge base `B1` and commits changing `[a.ex]` then `[b.ex]` are stored, and a client reports `H2` with merge base `B2`, without `H1` in its commits, and with commits changing `[a.ex]` then `[b.ex]`
- **THEN** the `H2` report has `head_kind` `rebase`

#### Scenario: Amended commit

- **WHEN** Git facts for `H1` with merge base `B` are stored and a client reports `H2` with merge base `B` that does not include `H1` in its commits
- **THEN** the `H2` report has `head_kind` `rewrite`

#### Scenario: Retry records nothing new

- **WHEN** a client reports `H1`, then `H2`, then the identical `H1` document again
- **THEN** the `H1` report still has `head_kind` `first` and the third report responds `200`

### Requirement: Verdict transitions are kept permanently

Each recompute of a `draft` or `open` change request whose verdict state, head or policy version differs from the stored verdict, or that stores its first verdict, MUST append one transition in the same transaction, holding `from_state`, `to_state`, `from_head`, `to_head`, `policy_version`, `cause`, `head_kind` and the time. `from_*` are null for the first verdict. Transitions MUST NOT be changed or deleted except with their change request; the event retention sweep MUST NOT delete them.

#### Scenario: Transitions outlive event retention

- **WHEN** the project event sweep deletes a change request's `verdict_changed` events older than 90 days
- **THEN** its verdict transitions are unchanged

### Requirement: A transition names its cause

A transition's `cause` MUST be `created` for the first verdict, `head` when the head changed, otherwise `policy` when the policy version changed, otherwise `inputs`. Its `head_kind` MUST be the kind of the Git facts row stored by the report that changed the head, and null for any other cause or when that report was a retry.

#### Scenario: Head change recorded

- **WHEN** a change request's verdict at `H1` is `blocked` and a client reports Git facts for `H2` with kind `fast_forward`, and the verdict becomes `pending`
- **THEN** a transition is recorded with `from_state` `blocked`, `to_state` `pending`, `from_head` `H1`, `to_head` `H2`, `cause` `head` and `head_kind` `fast_forward`

#### Scenario: Policy change recorded

- **WHEN** an admin writes policy version `5` and an `open` change request's verdict at an unchanged head moves from `needs_review` to `mergeable`
- **THEN** a transition is recorded with `cause` `policy` and `head_kind` null

#### Scenario: No change, no transition

- **WHEN** a recompute leaves the verdict state, head and policy version unchanged
- **THEN** no transition is recorded

### Requirement: Reason spans are kept permanently

Each recompute of a `draft` or `open` change request SHALL compare the new verdict's reasons, keyed by `rule`, `subject` and `outcome`, with the change request's open reason spans, in the same transaction. A key with no open span MUST open one with its key, the head, the policy version and the time. An open span whose key is gone MUST close with the head and the time. Spans MUST NOT change once closed and MUST be deleted only with their change request.

#### Scenario: Reasons-only change

- **WHEN** a change request at head `H` is `blocked` with two `must_failed` reasons, and a verify run clears one of them
- **THEN** that reason's span closes with `closed_head` `H` and `close_cause` `inputs`, the other span stays open, and no transition is recorded

#### Scenario: Unchanged reasons

- **WHEN** a recompute produces the same reasons as the open spans
- **THEN** no span is opened or closed

### Requirement: A closed span names its cause

A span closed by a recompute MUST record `close_cause` derived as for a transition (`head`, `policy` or `inputs`) and, for `head`, the `head_kind` of the report that moved the head. A reason whose `outcome` changes MUST close its span and open a new one. A merge report MUST close every open span with `merged`, and a move to `closed` with `closed`. A reopen opens new spans on its recompute.

#### Scenario: Fixed by a new head

- **WHEN** a `must_failed` span is open at `H1` and a client reports `H2` (`fast_forward`) whose verdict lacks that reason
- **THEN** the span closes with `closed_head` `H2`, `close_cause` `head` and `close_head_kind` `fast_forward`

#### Scenario: Outcome changed by policy

- **WHEN** a `path_match` span with outcome `needs_review` is open and a new policy version makes that reason `blocked`
- **THEN** the `needs_review` span closes with `close_cause` `policy` and a `blocked` span opens for the same rule and subject

#### Scenario: Merged past a reason

- **WHEN** a change request with an open `one_way_door` span is reported merged
- **THEN** the span closes with `close_cause` `merged`

### Requirement: A span measures the reason, not its answer

A span MUST stay open while its reason is in the verdict, whether or not its review item has an `approve` or `choose` answer. Review wait time is derived from review answers, whose `item_id` is the reason's `rule` and subject digest.

#### Scenario: Approved reason stays open

- **WHEN** a `one_way_door` span is open and a reviewer approves its item, making the verdict `mergeable`
- **THEN** the span is still open

### Requirement: Spans for reasons from before this change are marked inherited

When a change request has a stored verdict and no reason spans, its next recompute MUST open spans for keys already in the stored verdict with `inherited` true and `opened_at` the time of that recompute, so their durations are lower bounds.

#### Scenario: Open change request at deploy

- **WHEN** an `open` change request's stored verdict has a `spec_gap` reason, it has no spans, and a workflow run on its head triggers a recompute that keeps the reason
- **THEN** a `spec_gap` span opens with `inherited` true

### Requirement: The merge record counts fix iterations

A merge report SHALL store `fix_iterations` with the merge: the number of the change request's transitions with `cause` `head` and `head_kind` `fast_forward` or `rewrite` whose `from_head` had an earlier transition to `blocked` or `needs_review`. It MUST be null when any of its Git facts rows has no `head_kind`. It MUST NOT change after the merge is recorded.

#### Scenario: Two fixes after a block

- **WHEN** a change request was `blocked` at `H1`, a client reported `H2` (`fast_forward`), it became `needs_review` at `H2`, a client reported `H3` (`rewrite`), it became `mergeable`, and it is reported merged
- **THEN** `merge.head_count` is `3` and `merge.fix_iterations` is `2`

#### Scenario: Rebases are not fixes

- **WHEN** a change request was `blocked` at `H1`, a client reported `H2` with kind `rebase`, and it is reported merged
- **THEN** `merge.head_count` is `2` and `merge.fix_iterations` is `0`

#### Scenario: New head before any grade

- **WHEN** a change request's verdict at `H1` was only ever `pending`, a client reported `H2` (`fast_forward`), and it is reported merged
- **THEN** `merge.fix_iterations` is `0`

#### Scenario: History from before this change

- **WHEN** a change request has a Git facts row stored before this change and is reported merged
- **THEN** `merge.head_count` counts every head and `merge.fix_iterations` is null

### Requirement: The merge record counts heads

A merge report SHALL store `head_count` with the merge: the number of distinct heads with stored Git facts for the change request. It MUST NOT change after the merge is recorded.

#### Scenario: Merge without Git facts

- **WHEN** a client reports a merge for a change request that has no Git facts
- **THEN** `merge.head_count` is `0` and `merge.fix_iterations` is `0`

#### Scenario: Retarget counts one head

- **WHEN** Git facts for `H1` are stored for targets `a` and `main` and the change request is reported merged
- **THEN** `merge.head_count` is `1`

### Requirement: Git facts reads return the head kind

`GET .../change-requests/:number/git-facts/:head` SHALL include `previous_head` and `head_kind` of the stored report, both null for a report stored before they existed.

#### Scenario: Git facts head kind

- **WHEN** a report for `H2` was stored with `previous_head` `H1` and `head_kind` `fast_forward`, and a client reads `git-facts/H2`
- **THEN** the read has `previous_head` `H1` and `head_kind` `fast_forward`
