# stored-changes Specification

## Requirements

### Requirement: A push stores a new version of a change
`POST /api/v1/projects/:project/changes` SHALL accept a JSON body with `files`, an object from path to file text, and `source`, `{commit, branch, dirty}`. It SHALL take the change id only from `change.md`'s front matter `id`, store the files byte for byte as the change's next version (version 1 for a new change), and answer `201` with the new version and `replaced_version`, the number of the version that was latest before the push, or null for a new change.

### Requirement: A push is checked only for what the server relies on
A push SHALL be refused with `422`, storing nothing, unless `change.md` is present with front matter whose `format` is `goodflows-change/1`, whose `id` is 1 to 64 bytes matching `[a-z0-9][a-z0-9-]*`, and whose `status` is `proposed`, `approved` or `archived`, and unless `qa-scenarios.md`, when present, passes the front matter check the scenario-set upload applies, with `source: intent` and `change` equal to that id. No other `goodflows change validate` rule SHALL refuse a push.

### Requirement: Size, door, capabilities and depends_on are read when well formed
The server SHALL store `size`, `door`, `capabilities` and `depends_on` from `change.md`'s front matter with each version when each has its `goodflows-change/1` shape, and null for each that is missing or malformed, without refusing the push.

### Requirement: A push carries only the files of a goodflows change
A push SHALL be refused with `422`, storing nothing, when any path is not `change.md`, `qa-scenarios.md`, `verification.md`, or `specs/<capability>/spec.md` where `<capability>` is one or more `/`-separated segments, each matching `[a-z0-9][a-z0-9-]*`, or any path longer than 512 bytes, or any file containing U+0000, naming the path at fault.

### Requirement: A push is limited in files and bytes
A push SHALL be refused with `422`, storing nothing, when it has more than 100 files or more than 2,097,152 UTF-8 bytes of file text in total, and with `413` when its request body exceeds 16 MiB. A body that is not valid JSON SHALL be `400`, and one that is not `application/json` SHALL be `415`, as on the other strict JSON routes. Every stored version SHALL be kept until its change is deleted.

### Requirement: An identical push stores no version
When a push's paths and every file's bytes equal the change's latest version, the server SHALL store no version, record no event, and answer `200` with `duplicate: true` and the latest version unchanged, including the `source` of the push that created it, with `replaced_version` equal to that latest version's number.

### Requirement: The push source is stored as given
The server SHALL store `source` with the version it creates, accepting `commit` as a 7 to 64 character lowercase hex SHA or null, `branch` as 1 to 256 bytes without control characters or null, and `dirty` as a boolean, and SHALL NOT check them against anything else. A push without a well-formed `source`, or with any key other than `files` and `source` at the top level or `commit`, `branch` and `dirty` in `source`, SHALL be `422`.

### Requirement: An archived change takes no further pushes
A push whose change's latest stored version has status `archived` SHALL be refused with `409`, storing nothing, with the body `errors: {error: "change_archived", detail}`, unless it is identical to that version; a push that also fails a `422` check SHALL be `422`. A push whose own status is `archived` SHALL be stored like any other status.

### Requirement: Changes are listed page by page
`GET /api/v1/projects/:project/changes` SHALL list the project's stored changes by latest version, newest latest push first with ties broken by id, taking `limit` (1 to 200, default 50), `cursor`, and `status` (`proposed`, `approved` or `archived`, matched against the latest version), and SHALL return `next_cursor`, null on the last page. Each row SHALL carry `change_requests`: every change request of the project whose `change_id` equals the row's id, as number and state ordered by number, and `[]` when there is none, for `sk_` and `pk_` keys alike. A malformed parameter SHALL be `422`.

### Requirement: Reading a change returns its latest version and linked change requests
`GET /api/v1/projects/:project/changes/:change_id` SHALL return the latest version: the id, its version number, status, size, door, capabilities, depends_on, `pushed_at`, `source`, the pusher, each file's path and text, and every change request of the project whose `change_id` equals the id, as number and state. An unknown id SHALL be `404`.

### Requirement: A change's versions can be listed and read one by one
`GET /api/v1/projects/:project/changes/:change_id/versions` SHALL list the versions newest first, page by page with `limit` (1 to 200, default 50), `cursor` and `next_cursor`, each with its number, its own status, `pushed_at`, `source`, the pusher and `latest` (true only for the latest version). `GET /api/v1/projects/:project/changes/:change_id/versions/:n` SHALL return version `n` with its files, its own status, the pusher, and the change's `latest_status`. An unknown id or version SHALL be `404`; on the versions list an unknown id SHALL be `404` for every key. A malformed `limit` or `cursor` on the versions list SHALL be `422`.

### Requirement: Key access to stored changes
Any `sk_` key of the account SHALL push, read and delete the project's stored changes and see each version's pusher. A `pk_` key SHALL list changes and list versions, with the pusher null. In the versions list a `pk_` key SHALL see only each version's number, status, `pushed_at`, `source` and `latest`, with the pusher null. A `pk_` request for the change or for one version SHALL be `403`, whether or not the id exists. `ck_` keys and other accounts' keys SHALL be refused as on the other project routes.

### Requirement: A delete removes the change unless a change request links it
`DELETE /api/v1/projects/:project/changes/:change_id` SHALL remove the change and every version and answer `204`; an unknown id SHALL be `404`. While any change request of the project, in any state, has that `change_id`, it SHALL be refused with `409`, removing nothing, and the body SHALL list those change requests as number and state. A delete SHALL be serialized with change request opens and pushes of the same id: a change request committed before the delete commits makes it `409`, and a push committed after it starts a new change at version 1.

### Requirement: Stored changes block project deletion
Deleting a project SHALL be refused while the project has any stored change, as it is while the project has change requests.

### Requirement: Opening a change request does not need a stored change
Opening a change request with a `change_id` SHALL succeed whether or not a stored change with that id exists.

### Requirement: Pushes and deletes are recorded as project events
A push that stores a version and a successful delete SHALL each record one event in the project event feed, with no change request number, naming the change id and, for a push, the version number. A refused request SHALL record none.

### Requirement: Concurrent pushes never lose a version
When pushes of one change are accepted concurrently, each that is not identical to the version latest when it commits SHALL get its own consecutive version number, and none SHALL be lost or overwrite another. No push SHALL be refused for having been sent against an older version.

### Requirement: The stored-change routes are in the OpenAPI document
Every stored-change route SHALL be described in the OpenAPI document with its parameters, request body, and every response status it returns.
