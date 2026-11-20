## MODIFIED Requirements

### Requirement: The body is a run-history document
The body SHALL be one goodflows run-history JSON object with `schema_version` `1`. Its required keys are `schema_version`, `workflow`, `run_id`, `started_at`, `outcome`, `duration_ms`, `parallelism`, `graph_sha256`, `max_in_flight`, `host`, and `results`. Its optional keys are `environment`, `requested_jobs`, `source`, `parent_run_id`, `caller_job`, `links`, `ci`, and `graph`. The body MUST NOT carry a project or account: `project`, `account_id`, and any other key are unknown fields (`422`).

#### Scenario: Minimal document
- **WHEN** a client posts a document with only the required keys and an empty `results` array
- **THEN** the API responds `201`

#### Scenario: Unsupported schema version
- **WHEN** a client posts a document whose `schema_version` is `2`
- **THEN** the API responds `422` with an error on `schema_version` and stores nothing

#### Scenario: Body names the project
- **WHEN** a client posts a document containing a `project` key
- **THEN** the API responds `422` with `has an unknown field` on `body` and stores nothing

#### Scenario: Upload envelope
- **WHEN** a client posts a document with `source.branch`, `ci`, and `graph`
- **THEN** the API responds `201` and stores all three as given

#### Scenario: Links
- **WHEN** a client posts a document with `schema_version` `1` and `links` `{"threads": ["https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"], "tickets": ["GOO-291"]}`
- **THEN** the API responds `201` and stores `links` as given

### Requirement: The list can be filtered
The list SHALL accept the exact-match filters `workflow`, `environment`, `outcome`, `commit` (`source.commit`), `branch` (`source.branch`), `event` (`ci.event`), and `graph_sha256`, and the link filters `ticket` and `thread_url`, combined with AND. A run without `source.branch` never matches `branch`, and a run without `ci.event` never matches `event`. A filter value, `limit`, or `cursor` that breaks its rule MUST return `422` on that parameter. Unknown query parameters SHALL be ignored.

#### Scenario: Same graph across commits
- **WHEN** a client lists with `workflow=ci&graph_sha256=<hex>`
- **THEN** only runs of workflow `ci` with that graph hash are returned

#### Scenario: Branch and event
- **WHEN** a client lists with `branch=main&event=push`
- **THEN** only runs whose `source.branch` is `main` and whose `ci.event` is `push` are returned

#### Scenario: Pull-request run without a branch
- **WHEN** a stored run has `ci.event` `pull_request` and no `source.branch`, and a client lists with `branch=main`
- **THEN** that run is not returned

#### Scenario: Ticket combined with another filter
- **WHEN** a client lists with `ticket=GOO-291&branch=main`
- **THEN** only runs that name ticket `GOO-291` and whose `source.branch` is `main` are returned

#### Scenario: Invalid outcome filter
- **WHEN** a client lists with `outcome=green`
- **THEN** the API responds `422` with an error on `outcome`

#### Scenario: Unknown query parameter
- **WHEN** a client lists with `color=blue`
- **THEN** the API responds `200` and does not filter on `color`

#### Scenario: Invalid name filter
- **WHEN** a client lists with a `workflow` of 65 bytes, or an `environment` or `event` that is only whitespace
- **THEN** the API responds `422` with an error on that parameter

#### Scenario: Invalid branch filter
- **WHEN** a client lists with a `branch` of 257 bytes, an empty `branch`, or a `branch` containing a newline
- **THEN** the API responds `422` with an error on `branch`

### Requirement: Public keys do not see command text or errors
For a public (`pk_`) key, every `results` entry in `document` MUST have `command` and `error` null, every `graph` job and step MUST have `command` and any `condition` `text` null, and `links.threads`, when present, MUST be null. Every other field, such as job names, dependencies, partitions, `call`, condition `kind`, and `links.tickets`, MUST be as stored. A document without `links.threads` MUST NOT gain it. Private keys MUST see the document as stored. The stored row MUST NOT change.

#### Scenario: Public key reads a run
- **WHEN** a client with a `pk_` key shows a run whose results have commands and errors
- **THEN** every result in `data.document` has `command` null and `error` null, every other field is as stored, and a later `sk_` show of that run still has the stored `command` and `error`

#### Scenario: Public key reads a graph
- **WHEN** a client with a `pk_` key shows a run whose graph has job and step commands and condition text
- **THEN** each graph job and step has `command` null, each condition has `text` null and its `kind` as stored, and a later `sk_` show returns the graph as stored

#### Scenario: Public key reads links
- **WHEN** a client with a `pk_` key shows a run whose `links` has `threads` and `tickets` `["GOO-291"]`
- **THEN** `data.document.links.threads` is null, `data.document.links.tickets` is `["GOO-291"]`, and a later `sk_` show returns `links` as stored

#### Scenario: Public key reads tickets only
- **WHEN** a client with a `pk_` key shows a run whose `links` is `{"tickets": ["GOO-291"]}`
- **THEN** `data.document.links` is `{"tickets": ["GOO-291"]}` with no `threads` key

## ADDED Requirements

### Requirement: Uploads may carry links
`links`, when present, MUST be an object with only `threads` (1 to 32 thread URLs) and `tickets` (1 to 32 tickets), both omit-only, and at least one of them. An empty `links` MUST return `422` with `must not be empty` on `links`. Any other key in `links` is an unknown field (`422`). The server SHALL store `links` in the document as given.

#### Scenario: Tickets only
- **WHEN** a document's `links` is `{"tickets": ["GOO-291"]}`
- **THEN** the API responds `201`

#### Scenario: Empty links
- **WHEN** a document's `links` is `{}`
- **THEN** the API responds `422` with an error on `links` and stores nothing

#### Scenario: Unknown key in links
- **WHEN** a document's `links` contains a `prs` key
- **THEN** the API responds `422` with `has an unknown field` on `links`, the response does not contain `prs`, and nothing is stored

#### Scenario: Null links list
- **WHEN** a document's `links` is `{"threads": null, "tickets": ["GOO-291"]}`
- **THEN** the API responds `422` with an error on `links.threads`

#### Scenario: Empty list
- **WHEN** a document's `links.tickets` is `[]`
- **THEN** the API responds `422` with an error on `links.tickets`

#### Scenario: Too many entries
- **WHEN** a document's `links.threads` has 33 distinct valid URLs
- **THEN** the API responds `422` with an error on `links.threads`

#### Scenario: Exact retry with links
- **WHEN** a client uploads a document with `links`, then uploads it again with the `links` keys in a different order
- **THEN** the second response is `200` with `duplicate` true and the same `id`

#### Scenario: Retry with a different ticket spelling
- **WHEN** a stored run has `links.tickets` `["GOO-291"]` and a client uploads the same `run_id` with `links.tickets` `["goo-291"]`
- **THEN** the API responds `409` and the stored run is unchanged

### Requirement: Thread URLs are plain https URLs
Each `links.threads` entry MUST be a string of at most 2,048 bytes that parses as an absolute RFC 3986 URL with the scheme written as `https`, a nonempty host, a port of at most 65,535, and no userinfo, query, or fragment. An empty query (`?`) or an empty fragment (`#`) counts as present. Entries MUST be unique by exact string, and each repeat after the first MUST return `422` with `must be unique` on its own path.

#### Scenario: Amp thread URL
- **WHEN** a document's `links.threads` is `["https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"]`
- **THEN** the API responds `201`

#### Scenario: URL with a query
- **WHEN** a document's `links.threads[0]` is `https://ampcode.com/threads/T-1?token=secret`
- **THEN** the API responds `422` with an error on `links.threads[0]` and the response does not contain `secret`

#### Scenario: Bare query or fragment
- **WHEN** a document's `links.threads[0]` is `https://ampcode.com/threads/T-1?` or `https://ampcode.com/threads/T-1#`
- **THEN** the API responds `422` with an error on `links.threads[0]`

#### Scenario: Insecure or credentialed URL
- **WHEN** a document's `links.threads[0]` is `http://ampcode.com/threads/T-1`, `HTTPS://ampcode.com/threads/T-1`, or `https://user:pw@ampcode.com/threads/T-1`
- **THEN** the API responds `422` with an error on `links.threads[0]`

#### Scenario: Oversized URL
- **WHEN** a document's `links.threads[0]` is a valid normalized URL of 2,049 bytes
- **THEN** the API responds `422` with an error on `links.threads[0]`

#### Scenario: Duplicate thread
- **WHEN** a document's `links.threads` holds the same URL at index 0 and index 1
- **THEN** the API responds `422` with an error on `links.threads[1]`

### Requirement: Thread URL paths are RFC 3986 safe
Every byte of a `links.threads` entry's path MUST be an RFC 3986 `pchar` (an unreserved character, a sub-delim, `:`, or `@`) or `/`, and every `%` MUST start a `%` followed by two hex digits. An entry that breaks this MUST return `422` on its path.

#### Scenario: Characters outside pchar
- **WHEN** a document's `links.threads[0]` is `https://ampcode.com/threads/T-1[x]` or `https://ampcode.com/threads/T|1`
- **THEN** the API responds `422` with an error on `links.threads[0]`

#### Scenario: Malformed percent
- **WHEN** a document's `links.threads[0]` is `https://ampcode.com/threads/T-1%zz` or `https://ampcode.com/threads/T-1%`
- **THEN** the API responds `422` with an error on `links.threads[0]`

### Requirement: Thread URLs arrive normalized
Each `links.threads` entry MUST already be in the form `reqwest::Url` serializes: a host with no ASCII uppercase letter or `%`, an IP host in canonical form, no port that is empty, zero-padded, or 443, a nonempty path, and no `.` or `..` segment, including one spelled with `%2e`. Percent triplets MUST be kept as written, never decoded or recased. Any other entry MUST return `422` with `must be normalized` on its path. The server MUST NOT rewrite an entry.

#### Scenario: Not normalized
- **WHEN** a document's `links.threads[0]` is `https://AmpCode.com/threads/T-1`, `https://ampcode.com:443/threads/T-1`, `https://ampcode.com:0443/threads/T-1`, `https://ampcode.com`, `https://ampcode.com/a/../threads/T-1`, or `https://ampcode.com/a/%2E%2e/threads/T-1`
- **THEN** the API responds `422` with an error on `links.threads[0]` and stores nothing

#### Scenario: Host not in serialized form
- **WHEN** a document's `links.threads[0]` is `https://ex%61mple.com/threads/T-1`, `https://0x7f.1/threads/T-1`, or `https://[0:0:0:0:0:0:0:1]/threads/T-1`
- **THEN** the API responds `422` with an error on `links.threads[0]`

#### Scenario: Percent triplets kept as written
- **WHEN** a document's `links.threads` is `["https://ampcode.com/threads/a%7Eb", "https://ampcode.com/threads/a%2fb"]`
- **THEN** the API responds `201` and a later `sk_` show returns both strings unchanged

#### Scenario: WHATWG-serialized URL
- **WHEN** a document's `links.threads[0]` is `https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b`, as `reqwest::Url` serializes it
- **THEN** the API responds `201` and a later `sk_` show returns that exact string

### Requirement: Tickets are short printable IDs
Each `links.tickets` entry MUST be a string of 1 to 64 bytes, each a printable ASCII character from `!` to `~` other than `,`, so no whitespace, comma, control, or non-ASCII character is allowed. Entries MUST be unique ignoring ASCII case, and each repeat after the first MUST return `422` with `must be unique` on its own path. The server SHALL store each ticket as given.

#### Scenario: Ticket stored as written
- **WHEN** a document's `links.tickets` is `["goo-291", "GOO-300"]`
- **THEN** the API responds `201` and a later `sk_` show returns `["goo-291", "GOO-300"]`

#### Scenario: Duplicate ignoring case
- **WHEN** a document's `links.tickets` is `["GOO-1", "GOO-2", "goo-1"]`
- **THEN** the API responds `422` with an error on `links.tickets[2]`

#### Scenario: Whitespace or long ticket
- **WHEN** a document's `links.tickets[0]` is `GOO 1`, `GOO-1,GOO-2`, an empty string, a 65-byte string, or `GOÖ-1`
- **THEN** the API responds `422` with an error on `links.tickets[0]`

### Requirement: The list can be filtered by ticket
The list SHALL accept a `ticket` filter for every valid key, including `pk_` keys. The value MUST follow the ticket rule, or the API MUST return `422` on `ticket`. It SHALL match a run when any of the run's `links.tickets` equals it ignoring ASCII case. A run without `links.tickets` never matches. Tickets SHALL be indexed so the lookup does not read `payload`. Summaries SHALL NOT gain any field for links.

#### Scenario: Ticket ignoring case
- **WHEN** a stored run has `links.tickets` `["GOO-291"]` and a client lists with `ticket=goo-291`
- **THEN** that run is returned

#### Scenario: PR run and main run
- **WHEN** one stored run has `links` with threads and ticket `GOO-291`, another has only ticket `GOO-291`, and a client lists with `ticket=GOO-291`
- **THEN** both runs are returned, newest `started_at` first

#### Scenario: Invalid ticket filter
- **WHEN** a client lists with a `ticket` that contains a space
- **THEN** the API responds `422` with an error on `ticket` and the response does not contain the submitted value

#### Scenario: Run without links
- **WHEN** a stored run's document has no `links` and a client lists with `ticket=GOO-291`
- **THEN** that run is not returned

### Requirement: The list can be filtered by thread URL
The list SHALL accept a `thread_url` filter for every valid key, including `pk_` keys. The server SHALL lowercase its scheme and host, drop a port that is empty or 443, and turn an empty path into `/`, leaving percent triplets as written. The result MUST follow the thread URL rules, or the API MUST return `422` on `thread_url`. It SHALL match a run when one of the run's `links.threads` equals it, through an index rather than `payload`.

#### Scenario: Thread URL in another spelling
- **WHEN** a stored run has `links.threads` `["https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"]` and a client lists with `thread_url=HTTPS://AmpCode.com:443/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b`
- **THEN** that run is returned

#### Scenario: Percent triplets match as written
- **WHEN** a stored run has `links.threads` `["https://ampcode.com/threads/a%7Eb"]`, and a client lists with `thread_url=https://ampcode.com/threads/a%7eb`, then with `thread_url=https://ampcode.com/threads/a~b`
- **THEN** neither list returns that run

#### Scenario: Public key filters by thread
- **WHEN** a client with a `pk_` key lists with a `thread_url` that a stored run names
- **THEN** the API responds `200` and returns that run's summary, which has no links field

#### Scenario: Invalid thread filter
- **WHEN** a client lists with a `thread_url` whose query string is `token=secret`
- **THEN** the API responds `422` with an error on `thread_url` and the response does not contain `secret`

### Requirement: Runs without links are unaffected
A document without `links` MUST validate, store, retry, list, and show exactly as it did before `links` existed. Runs stored before this change SHALL have no `links` in their document and SHALL match neither link filter. No stored document SHALL be rewritten.

#### Scenario: Older client upload
- **WHEN** a client that does not know `links` uploads a valid document, then retries it exactly
- **THEN** the first response is `201`, the second is `200` with `duplicate` true, and an `sk_` show returns the document as uploaded with no `links` key

#### Scenario: Run stored before links
- **WHEN** a run stored before this change is shown with an `sk_` or a `pk_` key
- **THEN** its `document` has no `links` key and is otherwise unchanged
