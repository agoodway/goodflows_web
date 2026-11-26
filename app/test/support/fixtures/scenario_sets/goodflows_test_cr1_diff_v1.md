---
format: qa-scenarios/2
source: diff
branch: "feat/todo-crud"
base: "main"
revision: "2a2141c"
review: "1"
scenarios:
  - id: 1
    name: "Create todos and see them in the list"
    priority: must
  - id: 2
    name: "Mark a todo done without changing its title"
    priority: must
  - id: 3
    name: "Delete a todo and never reuse its id"
    priority: must
  - id: 4
    name: "Unknown todo id answers 404"
    priority: should
  - id: 5
    name: "Title length limits on create and update"
    priority: should
  - id: 6
    name: "Regression: Health check still answers"
    priority: could
regressions:
  - "Health check, served by the same app the todos router is mounted on: scenario 6"
---

# QA: feat: add in-memory todo CRUD endpoints

feat/todo-crud against main · goodflows change request 1

## What changed

An API client can now keep a todo list: create todos, list them, read one, rename it or mark it done, and delete it. The list lives in the server's memory and starts empty on every start.

```text
POST /todos {"title"}  GET /todos  GET|PATCH|DELETE /todos/{id}
```

## Setup

- Run: `uv run uvicorn app.main:app` from the branch, or the verify skill's `verify.sh launch`. Every scenario starts from a fresh server.
- Accounts: none, the API has no authentication.
- Data: none, the list starts empty.
- Flags: none.

## Checklist

Cap 25: the change touches one area, the todo endpoints, and one regression flow.

- [ ] 1. Create todos and see them in the list (Must)
- [ ] 2. Mark a todo done without changing its title (Must)
- [ ] 3. Delete a todo and never reuse its id (Must)
- [ ] 4. Unknown todo id answers 404 (Should)
- [ ] 5. Title length limits on create and update (Should)
- [ ] 6. Regression: Health check still answers (Could)

## Scenarios

### 1. Create todos and see them in the list (Must)

Why: creating and listing is the main path, and every other feature starts from it.

1. Send `POST /todos` with `{"title":"buy milk"}`.
   - Expect: status `201` and body `{"id":1,"title":"buy milk","done":false}`.
2. Send `POST /todos` with `{"title":"walk dog"}`.
   - Expect: status `201` and body `{"id":2,"title":"walk dog","done":false}`.
3. Send `GET /todos`.
   - Expect: status `200` and body `[{"id":1,"title":"buy milk","done":false},{"id":2,"title":"walk dog","done":false}]`.
4. Send `GET /todos/2`.
   - Expect: status `200` and body `{"id":2,"title":"walk dog","done":false}`.

### 2. Mark a todo done without changing its title (Must)

Why: an update that wipes the fields it was not sent would lose the user's title.

1. Send `POST /todos` with `{"title":"buy milk"}`.
   - Expect: status `201` and `"id":1`.
2. Send `PATCH /todos/1` with `{"done":true}`.
   - Expect: status `200` and body `{"id":1,"title":"buy milk","done":true}`.
3. Send `PATCH /todos/1` with `{"title":"buy oat milk"}`.
   - Expect: status `200` and body `{"id":1,"title":"buy oat milk","done":true}`.
4. Send `GET /todos/1`.
   - Expect: status `200` and body `{"id":1,"title":"buy oat milk","done":true}`.

### 3. Delete a todo and never reuse its id (Must)

Why: a reused id would make a client's stale reference point at someone else's todo.

1. Send `POST /todos` with `{"title":"a"}`, then with `{"title":"b"}`.
   - Expect: ids `1` and `2`.
2. Send `DELETE /todos/2`.
   - Expect: status `204` and an empty body.
3. Send `GET /todos/2`.
   - Expect: status `404` and body `{"detail":"Todo not found"}`.
4. Send `POST /todos` with `{"title":"c"}`.
   - Expect: status `201` and `"id":3`, not `2`.
5. Send `GET /todos`.
   - Expect: todos `1` and `3` only.

### 4. Unknown todo id answers 404 (Should)

Why: a client must be able to tell a missing todo from a server error.

1. Send `GET /todos/99`.
   - Expect: status `404` and body `{"detail":"Todo not found"}`.
2. Send `PATCH /todos/99` with `{"done":true}`.
   - Expect: status `404` and body `{"detail":"Todo not found"}`.
3. Send `DELETE /todos/99`.
   - Expect: status `404` and body `{"detail":"Todo not found"}`.

### 5. Title length limits on create and update (Should)

Why: titles must be 1 to 200 characters, and both sides of each limit decide whether a client's input is kept.

1. Send `POST /todos` with `{"title":""}`.
   - Expect: status `422` and the error names the `title` field.
2. Send `POST /todos` with a title of 201 `x` characters.
   - Expect: status `422` and the error names the `title` field.
3. Send `POST /todos` with a title of 200 `x` characters.
   - Expect: status `201` and `"id":1`.
4. Send `PATCH /todos/1` with `{"title":""}`.
   - Expect: status `422`.
5. Send `GET /todos/1`.
   - Expect: the title is still the 200 `x` characters.

### 6. Regression: Health check still answers (Could)

Why: the todo routes are mounted on the same app, and a broken mount would take the health check down with them.

1. Send `GET /health`.
   - Expect: status `200` and body `{"status":"ok"}`.

## Regression checks

- Health check, served by the same app the todos router is mounted on: scenario 6

## Not covered by these scenarios

- Two creates at the same moment getting the same id. No tester can time requests that closely; no test in the diff covers it, and the claims list it as an open risk.
- Todos surviving a restart. They do not by design; the claims list it as an open risk.

## Questions for the developer

- None.
