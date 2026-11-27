---
paths:
  - "app/lib/good_flows/stored_changes.ex"
  - "app/lib/good_flows/stored_changes/**"
  - "app/lib/good_flows_web/controllers/api/v1/stored_change_*.ex"
  - "app/lib/good_flows_web/schemas/stored_change_*.ex"
  - "app/priv/repo/migrations/*_create_stored_changes.exs"
  - "app/test/good_flows/stored_changes*.exs"
  - "app/test/good_flows_web/controllers/api/v1/stored_change_controller_test.exs"
---

# Stored changes API

An API client stores the files of a goodflows change (`change.md`, `qa-scenarios.md`, `verification.md` and `specs/<capability>/spec.md`) under a project before any change request exists for it, through `/api/v1/projects/<slug>/changes`. Every push that changes a file is kept as a new version, so the change's history can be listed and read, and an identical push stores nothing. Private keys push, read and delete; public keys list changes and versions but cannot read a change or a version. A change that a change request links cannot be deleted.

## Sub-features

- `changes-push` stores a new change as version 1 (`201`, `replaced_version` null), a changed push as the next version (`201`, `replaced_version` the previous number), and an identical push as nothing new (`200`, `duplicate` true).
- `changes-push-refused` refuses a push with a bad path, a bad `change.md` or `source`, or an extra key with `422` naming the field, and a push over an archived change with `409`, storing nothing.
- `changes-list` lists the project's changes, newest push first, each row with its linked change requests as number and state, with `limit`, `cursor`, `next_cursor` and `status`.
- `changes-show` reads a change's latest version with its files and linked change requests, and one version with its files and the change's `latest_status`.
- `changes-versions` lists a change's versions newest first, with `latest` true only for the newest.
- `changes-public-key` lets a public key list changes and versions, the versions list showing only `version`, `status`, `pushed_at`, `source`, `latest` and `pushed_by` null, and answers `403` with a detail naming the private key for a change or version read, known id or not.
- `changes-delete` deletes a change and every version (`204`), refuses it with `409` listing the linking change requests, and answers `404` naming the id once it is gone.

## How to get to it (user POV)

- `POST $GF_URL/api/v1/projects/<slug>/changes` with `{"files": {<path>: <text>}, "source": {"commit", "branch", "dirty"}}`, or `goodflows change push` from a checkout once the CLI ships it.
- `GET …/changes`, `GET …/changes/<id>`, `GET …/changes/<id>/versions`, `GET …/changes/<id>/versions/<n>` and `DELETE …/changes/<id>`.
- Swagger UI at `$GF_URL/api/v1/docs`, under `Stored changes`.

## Driving it with control-goodflows

Preconditions:

- Baseline state. A private key (`verify-private`) and a public key (`verify-public`) of Acme Corp created on the API keys page, as in [API keys](./api-keys.md). Keep each token in a file outside the run folder and export the one a step needs as `GF_API_KEY`.
- A project `verify-changes` created with the private key: `$C api changes-project POST /api/v1/projects '{"slug":"verify-changes"}'` returns 201.
- A push body in a file: `change.md` with front matter `format: goodflows-change/1`, `id: add-login`, `status: proposed`, and `source` `{"commit": "<40 hex>", "branch": "feat/login", "dirty": false}`.

- **Push.** With the private key, run `$C api changes-push1 POST /api/v1/projects/verify-changes/changes "$(cat push1.json)"`. It returns 201 with `version` 1, `replaced_version` null and `duplicate` false. Push it again: 200 with `duplicate` true and `version` 1. Change one line of `change.md` and push: 201 with `version` 2 and `replaced_version` 1.
- **Refused push.** Push a body with a `notes.txt` file: 422 naming `files.notes.txt`. Push `change.md` without `format`: 422 naming `files.change.md.format`. Push with `source.branch` holding a tab: 422 naming `source.branch`. `$C db "select count(*) from stored_change_versions" stored-changes/db-versions.txt` still shows 2.
- **List.** Open a change request with `change_id` `add-login` (`$C api changes-cr POST /api/v1/projects/verify-changes/change-requests '{"title":"Login","source_branch":"feat/login","change_id":"add-login"}'`), then run `$C api changes-list GET /api/v1/projects/verify-changes/changes`. It returns 200 with one row: `change_id` `add-login`, `version` 2, `status` `proposed`, `change_requests` `[{"number": 1, "state": "draft"}]`, and `next_cursor` null.
- **Show.** `$C api changes-show GET /api/v1/projects/verify-changes/changes/add-login` returns version 2 with every file's `path` and `text` and the same `change_requests`. `…/versions/1` returns version 1's files with `latest_status` `proposed`. `…/versions/9` returns 404 with `add-login has no version 9`.
- **Versions.** `$C api changes-versions GET /api/v1/projects/verify-changes/changes/add-login/versions` returns versions 2 and 1, with `latest` true only on 2 and `pushed_by.user_id` set.
- **Public key.** With the public key, the list returns the same row with its `change_requests`, and the versions list returns rows holding only `version`, `status`, `pushed_at`, `source`, `latest` and `pushed_by` null. `GET …/changes/add-login` and `GET …/changes/unknown` both return 403 with `Public (pk_) keys cannot read a stored change or one of its versions; use a private (sk_) key, …`. A push or a delete returns 403.
- **Delete.** With the private key, `$C api changes-delete-refused DELETE /api/v1/projects/verify-changes/changes/add-login` returns 409 whose `change_requests` lists number 1. Push a second change `add-logout`, delete it: 204 with no body. Delete it again: 404 with `No stored change add-logout in this project`. The event feed at `GET /api/v1/projects/verify-changes/events` holds one `change_deleted` event naming `add-logout`.
- **Proof.** Keep the `api/changes-*` files, the `db` output, and the event feed read.

## Gotchas

- The id comes only from `change.md`'s front matter, never from the URL, so a push to `…/changes` with another id in the path does not exist as a route.
- A duplicate is decided by the set of paths and every file's bytes. Adding or removing a trailing newline is a new version.
- Once the latest version's status is `archived`, every push of that id except an identical one is 409. Use a new id for a new change in the same run.
- A change request links a change by `change_id` alone, and a closed or merged one still blocks the delete. A run that needs to delete a linked change must use another id; change requests cannot be deleted.
- `$C api` takes the body as one argument. Build bodies with `jq -n` into a file and pass `"$(cat file)"`, since `change.md` text holds newlines and quotes.
