---
paths:
  - "app/lib/good_flows/change_requests.ex"
  - "app/lib/good_flows/change_requests/**"
  - "app/lib/good_flows/scenario_sets.ex"
  - "app/lib/good_flows/scenario_sets/**"
  - "app/lib/good_flows/review.ex"
  - "app/lib/good_flows/review/**"
  - "app/lib/good_flows/merge_leases.ex"
  - "app/lib/good_flows/merge_leases/**"
  - "app/lib/good_flows_web/controllers/api/v1/change_request_*.ex"
  - "app/lib/good_flows_web/controllers/api/v1/scenario_set_*.ex"
  - "app/lib/good_flows_web/controllers/api/v1/review_controller.ex"
  - "app/lib/good_flows_web/controllers/api/v1/review_json.ex"
  - "app/lib/good_flows_web/controllers/api/v1/merge_lease_*.ex"
  - "app/lib/good_flows_web/plugs/load_change_request.ex"
  - "app/lib/good_flows_web/schemas/change_request*.ex"
  - "app/lib/good_flows_web/schemas/claims_response.ex"
  - "app/lib/good_flows_web/schemas/git_facts_*.ex"
  - "app/lib/good_flows_web/schemas/verdict*.ex"
  - "app/lib/good_flows_web/schemas/scenario_set_*.ex"
  - "app/lib/good_flows_web/schemas/review_answer*.ex"
  - "app/lib/good_flows_web/schemas/review_item.ex"
  - "app/lib/good_flows_web/schemas/review_packet_response.ex"
  - "app/lib/good_flows_web/schemas/review_task*.ex"
  - "app/lib/good_flows_web/schemas/merge_lease*.ex"
  - "app/test/good_flows/change_requests*.exs"
  - "app/test/good_flows/change_requests/**"
  - "app/test/good_flows/scenario_sets*.exs"
  - "app/test/good_flows/scenario_sets/**"
  - "app/test/good_flows/review/**"
  - "app/test/good_flows/merge_leases*.exs"
  - "app/test/good_flows/merge_leases/**"
  - "app/test/good_flows_web/controllers/api/v1/change_request_*.exs"
  - "app/test/good_flows_web/controllers/api/v1/scenario_set_controller_test.exs"
  - "app/test/good_flows_web/controllers/api/v1/review_controller_test.exs"
  - "app/test/good_flows_web/controllers/api/v1/review_isolated_test.exs"
  - "app/test/good_flows_web/controllers/api/v1/merge_lease_controller_test.exs"
---

# Change requests API

An agent takes a branch through a change request, the record that replaces a pull request, with the goodflows CLI and a dashboard-created private key. It opens a draft for the branch, reports Git facts for each pushed head, uploads a scenario set and the claims file, and reads a verdict of `pending`, `blocked`, `needs_review`, or `mergeable`. A person answers what the policy flagged, and the agent takes the merge slot, merges on the Git host, and reports the merge. The server never talks to the Git host. Verify runs that grade the set are in [Verify runs API](./verify-runs-api.md).

## Sub-features

- `cr-open` opens a draft change request for the current branch, numbered per project, with `git_facts_missing` as its only reason.
- `cr-git-facts` reports Git facts for the pushed head with `cr push`, after which the verdict names the head.
- `cr-scenarios` uploads a `qa-scenarios/2` diff set as version 1 of the change request's diff set.
- `cr-claims` uploads the `change-claims/2` claims file for the head and turns its questions and weak proofs into review items.
- `cr-ready` moves the draft to `open`.
- `cr-review` lists the items that need a person, each with the answer commands it allows, and records answers bound to the head.
- `cr-lease` takes the target branch's merge slot for a mergeable head and prints a lease id.
- `cr-merged` records the merge with the verdict at merge and frees the lease.
- `cr-claims-invalid` refuses a claims file the server cannot accept, such as one with an integer question `id`, with 422 and stores nothing.

## How to get to it (user POV)

- Run `goodflows cr …` from a Git checkout whose `goodflows.toml` has a `[reporting]` block naming the project, with `GOODFLOWS_URL` set to `$GF_URL` and `GOODFLOWS_API_KEY` set to a dashboard-created `sk_` key.
- Each route is also under `$GF_URL/api/v1/projects/<slug>/change-requests` in Swagger UI at `$GF_URL/api/v1/docs`.

## Driving it with control-goodflows

Preconditions:

- Baseline state, and a private key created in the dashboard while it showed Acme Corp, as in [API keys](./api-keys.md), exported as `GF_API_KEY`.
- A project: `$C api project POST /api/v1/projects '{"slug":"verify-cr"}'` returns 201.
- A goodflows CLI binary as `GF`: `goodflows` on `PATH`, or one built from agoodway/goodflows `main` with `cargo build --locked`. Export `GOODFLOWS_URL=$GF_URL GOODFLOWS_API_KEY=$GF_API_KEY`.
- A scratch checkout inside the run folder with a bare `origin`: `W=$GF_RUN_DIR/cr`, `git init -q --bare $W/origin.git`, `git init -q -b main $W/checkout`, and in the checkout `git config commit.gpgsign false`, a name and email, a `goodflows.toml` holding `[reporting]` with `project = "verify-cr"` and one `[[jobs]]` entry, one commit on `main` pushed to `origin`, `git remote set-head origin main`, then a branch `feat/hello` with one more commit.

Run every `$GF` command from `$W/checkout`.

- **Open.** Run `$GF cr open --title "feat: greet the world"`. It prints `Created change request #<n>` and `#<n> draft  feat/hello -> main`, and the verdict is `pending` with only `git_facts_missing`.
- **Push.** Run `$GF cr push -- -u origin HEAD`. It prints `Git facts: reported for <head>` and the verdict names that head, now `pending` on `claims_missing`.
- **Scenario set.** Write a `qa-scenarios/2` diff set with `revision` set to the short HEAD SHA at the path `$GF cr path --json` prints as `scenarios_path`. `$GF cr validate` prints `ok`, and `$GF cr scenarios upload` prints `Uploaded diff set of change request #<n> as version 1`. `$GF cr verdict` adds `scenario_results_missing [diff]` and a `diff set v1` line with every scenario not run.
- **Verify run.** Upload a run that passes the set, as in [Verify runs API](./verify-runs-api.md). The verdict's `diff set v1` line shows the passes and `counted runs: 1`.
- **Invalid claims.** Write a `change-claims/2` file at `$GF cr path` with `cr` set to the number, `head` set to HEAD, one `stated` `safe_because` fact, and one question whose `id` is a bare integer `1`. `$GF cr claims` gets `Error: cr claims failed: request rejected (HTTP 422)` with `{"errors":{"questions[0].id":["must be a string"]}}`, and the verdict still has `claims_missing`.
- **Claims.** Change the question `id` to `"1"`. `$GF cr claims` prints `Claims: uploaded`, and the verdict becomes `needs_review` with `open_items` and `proof_below_minimum`, `review: 0/2 items cleared`.
- **Ready.** Run `$GF cr ready`. It prints `#<n> open`.
- **Review.** Run `$GF cr review`. It lists `## Items to answer (2)`, each with an id such as `open_items:<digest>` and the `goodflows cr answer` commands it allows. Answer the question with `$GF cr answer <id> choose --option "<an option>"` and the proof item with `$GF cr answer <id> approve`. `$GF cr wait --until mergeable --timeout 30` exits 0 and prints `Verdict: mergeable`; the cleared reasons stay listed.
- **Lease.** Run `$GF cr lease acquire`. It prints `state: active`, the head, the base, and an `id`.
- **Merge.** Merge `feat/hello` into `main` in the checkout, push `main`, and run `$GF cr merged --commit HEAD --lease <id>`. It prints `#<n> merged` and `verdict at merge mergeable`.
- **Proof.** Run `$C db "select number, state, merged_without_mergeable_verdict from change_requests order by number" change-requests/db-rows.txt` (the merged row reads `merged|f`) and `$C db "select count(*) from merge_leases where state = 'active'"` (`0`). Keep the output of every `$GF` command in `change-requests/`.

## Gotchas

- The orb's global Git config signs commits, and a commit in the scratch checkout fails with `No signing key is available` unless that checkout sets `commit.gpgsign false`. A failed commit leaves you on `main`, and `cr open` then opens a change request from `main` to `main`. Close it with `$GF cr close -n <n>`.
- `cr open` needs `origin/HEAD`. Run `git remote set-head origin main` after the first push.
- The server requires question and decision `id` values in claims to be strings, such as `id: "1"`. A bare integer gets 422 `questions[0].id: must be a string`. `gs-change-request` writes quoted ids, and `goodflows cr validate` reports a bare one in CLI releases after `4ba3522`; an older CLI misses it.
- Without a policy, the verdict reaches `mergeable` once every item is answered. The policy rules for required workflows, coverage, and sensitive paths need `$GF policy set` with an owner's key, and coverage needs `$GF features sync`.
- Change requests are scoped to the key's project and account. A key made while the dashboard showed Globex Industries gets 404 for `verify-cr`.
