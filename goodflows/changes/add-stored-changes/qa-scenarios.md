---
format: qa-scenarios/2
source: intent
change: "add-stored-changes"
specs: uncommitted
review: null
scenarios:
  - id: 1
    name: "First push stores version 1"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A push stores a new version of a change"
        implied: true
      - capability: "stored-changes"
        requirement: "The push source is stored as given"
        implied: true
      - capability: "stored-changes"
        requirement: "Pushes and deletes are recorded as project events"
        implied: true
  - id: 2
    name: "Second push stores version 2 and names the replaced version"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A push stores a new version of a change"
        implied: true
      - capability: "stored-changes"
        requirement: "A change's versions can be listed and read one by one"
        implied: true
  - id: 3
    name: "Identical push stores nothing"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "An identical push stores no version"
        implied: true
      - capability: "stored-changes"
        requirement: "Pushes and deletes are recorded as project events"
        implied: true
  - id: 4
    name: "Push with a bad change.md or intent set is refused"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A push is checked only for what the server relies on"
        implied: true
  - id: 5
    name: "Push that fails only CLI validate rules is stored"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A push is checked only for what the server relies on"
        implied: true
      - capability: "stored-changes"
        requirement: "Size, door, capabilities and depends_on are read when well formed"
        implied: true
  - id: 6
    name: "Unknown paths are refused and nested spec paths are stored"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A push carries only the files of a goodflows change"
        implied: true
  - id: 7
    name: "Too many files or bytes are refused"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A push is limited in files and bytes"
        implied: true
  - id: 8
    name: "Malformed source is refused"
    priority: should
    covers:
      - capability: "stored-changes"
        requirement: "The push source is stored as given"
        implied: true
  - id: 9
    name: "An archived change takes no further pushes"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "An archived change takes no further pushes"
        implied: true
  - id: 10
    name: "List pages and filters by status"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "Changes are listed page by page"
        implied: true
  - id: 11
    name: "Read a change with its linked change requests"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "Reading a change returns its latest version and linked change requests"
        implied: true
      - capability: "stored-changes"
        requirement: "Opening a change request does not need a stored change"
        implied: true
  - id: 12
    name: "Read an older version"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A change's versions can be listed and read one by one"
        implied: true
  - id: 13
    name: "Public key lists but cannot read file text"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "Key access to stored changes"
        implied: true
  - id: 14
    name: "Delete is refused while a change request links the change"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A delete removes the change unless a change request links it"
        implied: true
  - id: 15
    name: "Delete removes every version and the id starts over"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "A delete removes the change unless a change request links it"
        implied: true
      - capability: "stored-changes"
        requirement: "Pushes and deletes are recorded as project events"
        implied: true
  - id: 16
    name: "Stored changes block project deletion"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "Stored changes block project deletion"
        implied: true
  - id: 17
    name: "Concurrent pushes each get a version"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "Concurrent pushes never lose a version"
        implied: true
  - id: 18
    name: "OpenAPI describes every stored-change route"
    priority: must
    covers:
      - capability: "stored-changes"
        requirement: "The stored-change routes are in the OpenAPI document"
        implied: true
---

# QA: add-stored-changes

Run these against a local GoodFlows Web server with one account, one project `web`, an `sk_` key and a `pk_` key of that account, and a valid `goodflows/changes/add-login/` directory to push.

## Scenarios

### 1. First push stores version 1 (Must)

1. With the `sk_` key, `POST /api/v1/projects/web/changes` with the files of `add-login` and `source` `{"commit": "<40-hex sha>", "branch": "feat/login", "dirty": false}`.
   - Expect: `201`; the change id is `add-login`, the version is 1, `replaced_version` is null, and `source` is returned as sent.
2. Read the project event feed.
   - Expect: one new event names `add-login` and version 1.
3. Push again with `commit` null and `branch` null after changing `change.md`.
   - Expect: `201`; version 2 stores `commit` and `branch` as null.

### 2. Second push stores version 2 and names the replaced version (Must)

1. Push `add-login` once, then change one line in `qa-scenarios.md` and push again.
   - Expect: the second push is `201` with version 2 and `replaced_version` 1.
2. `GET .../changes/add-login/versions`.
   - Expect: two versions; only version 2 has `latest` true.

### 3. Identical push stores nothing (Must)

1. Push `add-login` with `source.commit` A, then push the same files byte for byte with `source.commit` B.
   - Expect: the second push is `200` with `duplicate` true, the latest version number unchanged, `replaced_version` equal to that latest version number, and `source.commit` still A.
2. Read the versions list and the event feed.
   - Expect: no new version and no new event since the first push.

### 4. Push with a bad change.md or intent set is refused (Must)

1. Push files with no `change.md`.
   - Expect: `422`; no change is stored.
2. Push a `change.md` whose `format` is `goodflows-change/2`, then one whose `status` is `done`, then one whose `id` is `Add_Login`.
   - Expect: each is `422` naming the field; nothing is stored.
3. Push a valid `change.md` with id `add-login` and a `qa-scenarios.md` whose `change` is `add-logout`.
   - Expect: `422` naming `qa-scenarios.md`; nothing is stored.

### 5. Push that fails only CLI validate rules is stored (Must)

1. Push a `change.md` with a valid format, id and status, a requirement without a `Refs:` line in its delta, and `size: huge`.
   - Expect: `201`; the version is stored with `size` null and `door`, `capabilities` and `depends_on` as written.

### 6. Unknown paths are refused and nested spec paths are stored (Must)

1. Push files that include `notes.txt`.
   - Expect: `422` naming `notes.txt`; nothing is stored.
2. Push files that include `specs/review/answers/spec.md`.
   - Expect: `201`; reading the change lists `specs/review/answers/spec.md` with its text.

### 7. Too many files or bytes are refused (Must)

1. Push 101 spec delta files.
   - Expect: `422` naming the file limit; nothing is stored.
2. Push files whose text totals 2,097,153 bytes.
   - Expect: `422` naming the size limit; nothing is stored.
3. Push files whose text totals exactly 2,097,152 bytes, with characters that JSON must escape.
   - Expect: `201`.
4. Send a request body over 16 MiB.
   - Expect: `413`; nothing is stored.

### 8. Malformed source is refused (Should)

1. Push with no `source`, then with `dirty` as `"yes"`, then with `commit` as `xyz`, then with an extra `source.remote` key, then with a 300-byte `branch`.
   - Expect: each is `422`; nothing is stored.

### 9. An archived change takes no further pushes (Must)

1. Push `add-login` with `status: archived`.
   - Expect: `201`; the latest status is `archived`.
2. Push `add-login` again with `status: approved`.
   - Expect: `409`; no version is stored.
3. Push `add-login` with `status: approved` and an extra `notes.txt`.
   - Expect: `422`, not `409`; no version is stored.
4. Push the archived files again byte for byte.
   - Expect: `200` with `duplicate` true.

### 10. List pages and filters by status (Must)

1. Push three changes, `a`, `b` and `c` in that order, with `c` `approved` and the others `proposed`.
2. `GET .../changes?limit=2`.
   - Expect: `c` then `b`, and a non-null `next_cursor`; following it returns `a` and a null `next_cursor`.
3. `GET .../changes?status=approved`.
   - Expect: only `c`.
4. `GET .../changes?status=done` and `GET .../changes?limit=0`.
   - Expect: `422` for each.

### 11. Read a change with its linked change requests (Must)

1. Open a change request with `change_id` `add-login` before any change is pushed.
   - Expect: the change request is created.
2. Push `add-login`, then `GET .../changes/add-login`.
   - Expect: the latest version with every file's path and text, and the linked change requests list that change request's number and state.
3. `GET .../changes/unknown`.
   - Expect: `404`.

### 12. Read an older version (Must)

1. Push `add-login` twice with different files, the second with `status: archived`.
2. `GET .../changes/add-login/versions/1`.
   - Expect: version 1's files, its own status `proposed`, and `latest_status` `archived`.
3. `GET .../changes/add-login/versions/3`.
   - Expect: `404`.

### 13. Public key lists but cannot read file text (Must)

1. With the `pk_` key, list changes and list `add-login`'s versions.
   - Expect: `200` for both; the pusher is null.
2. With the `pk_` key, `GET .../changes/add-login`, `GET .../changes/add-login/versions/1` and `GET .../changes/unknown`.
   - Expect: `403` for all three.
3. With the `pk_` key, push and delete.
   - Expect: refused; nothing changes.

### 14. Delete is refused while a change request links the change (Must)

1. Push `add-login`, open a change request with `change_id` `add-login`, and close it.
2. `DELETE .../changes/add-login`.
   - Expect: `409` whose body lists the closed change request's number and state; every version is still readable.

### 15. Delete removes every version and the id starts over (Must)

1. Push `add-logout` twice; no change request links it.
2. `DELETE .../changes/add-logout`.
   - Expect: `204`; a second delete is `404`; `GET .../changes/add-logout` and `.../versions/1` are `404`, and the event feed has one event naming `add-logout`.
3. Push `add-logout` again.
   - Expect: `201` with version 1 and `replaced_version` null.

### 16. Stored changes block project deletion (Must)

1. Create a project with no recipes, runs or change requests, and push one change to it.
2. Delete the project with an owner's `sk_` key.
   - Expect: refused; the project and the change are still there.
3. Delete the change, then delete the project.
   - Expect: the project is deleted.

### 17. Concurrent pushes each get a version (Must)

1. Send ten pushes of `add-login` at once, each with different `change.md` text.
   - Expect: ten versions, numbered consecutively with no gap or repeat, and each push's files appear in exactly one version.

### 18. OpenAPI describes every stored-change route (Must)

1. Fetch the OpenAPI document.
   - Expect: it lists the push, list, read, versions, version and delete routes, each with its parameters, request body and response statuses.
