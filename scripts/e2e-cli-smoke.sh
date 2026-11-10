#!/usr/bin/env bash
# End-to-end smoke test: the goodflows CLI uploads run history to a local
# GoodFlows Web dev server (GOO-247). See "CLI end-to-end smoke" in
# .agents/README.md. Run from anywhere after .agents/setup:
#
#   scripts/e2e-cli-smoke.sh
#
# SMOKE_PORT (default 4123) is the port of the Phoenix server this script
# starts and stops. GOODFLOWS_BIN skips the CLI build and uses that binary;
# otherwise GOODFLOWS_CLI_REF (default main) of agoodway/goodflows is built.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
port=${SMOKE_PORT:-4123}
url="http://127.0.0.1:$port"
branch=goo-247-smoke
work=$(mktemp -d /tmp/goodflows-e2e.XXXXXX)
server_log="$work/server.log"
server_pid=
failures=0

[[ -f "$HOME/.local/share/goodflows/env" ]] && source "$HOME/.local/share/goodflows/env"

say() { printf '\n== %s\n' "$*"; }
check() { # check NAME COMMAND...
  if "${@:2}"; then echo "PASS  $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi
}

start_server() {
  (cd "$repo/app" && PORT=$port exec setsid mix phx.server >>"$server_log" 2>&1) &
  server_pid=$!
  for _ in $(seq 120); do
    curl -fsS -o /dev/null "$url/users/log-in" 2>/dev/null && return 0
    sleep 1
  done
  echo "server did not start; see $server_log" >&2
  exit 1
}
stop_server() {
  [[ -n $server_pid ]] || return 0
  kill -TERM -- "-$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=
}
trap stop_server EXIT

say "GoodFlows Web: mix setup and server on port $port"
if curl -s -o /dev/null "$url"; then
  echo "port $port is in use; set SMOKE_PORT" >&2
  exit 1
fi
"$repo/.agents/resume"
(cd "$repo/app" && mix setup >"$work/mix-setup.log" 2>&1) || {
  tail -40 "$work/mix-setup.log"
  exit 1
}
start_server

say "goodflows CLI"
if [[ -n ${GOODFLOWS_BIN:-} ]]; then
  goodflows=$GOODFLOWS_BIN
else
  if ! command -v cargo >/dev/null; then
    [[ -f "$HOME/.cargo/env" ]] || curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null
    source "$HOME/.cargo/env"
  fi
  cli_root="$HOME/.local/share/goodflows/cli"
  cargo install --quiet --locked --root "$cli_root" \
    --git https://github.com/agoodway/goodflows --branch "${GOODFLOWS_CLI_REF:-main}"
  goodflows="$cli_root/bin/goodflows"
fi
"$goodflows" --version

say "Account, private API key and project"
# The dashboard's API key page calls the same Accounts.create_api_key/2.
GOODFLOWS_API_KEY=$(cd "$repo/app" && mix run -e '
  alias GoodFlows.{Accounts, Repo}
  user = Accounts.get_user_by_email("user@example.com")
  account = Repo.get_by!(Accounts.Account, name: "Acme Corp")
  {:ok, {_key, token}} =
    Accounts.create_api_key(Accounts.get_account_user(user, account), %{
      "name" => "e2e-cli-smoke",
      "type" => "private"
    })
  IO.puts("TOKEN=" <> token)
' 2>/dev/null | sed -n 's/^TOKEN=//p')
export GOODFLOWS_URL=$url GOODFLOWS_API_KEY
project="e2e-smoke-$(date +%s)"
auth=(-H "Authorization: Bearer $GOODFLOWS_API_KEY")
curl -fsS "${auth[@]}" -H 'content-type: application/json' \
  -d "{\"slug\":\"$project\"}" "$url/api/v1/projects" | jq -c '.data | {slug, id}'
runs_url="$url/api/v1/projects/$project/workflow-runs"

say "Workflows in a git checkout on branch $branch ($work/checkout)"
mkdir "$work/checkout" && cd "$work/checkout"
git init -q -b "$branch"
cat >goodflows.toml <<EOF
[reporting]
project = "$project"
history = true

[[jobs]]
name = "lint"
command = "echo lint ok"

[[jobs]]
name = "test"
command = "echo test ok"
depends_on = ["lint"]

[[workflows.release.jobs]]
name = "prepare"
command = "echo prepare"

[[workflows.release.jobs]]
name = "checks"
workflow = "default"
depends_on = ["prepare"]

[[workflows.release.jobs]]
name = "publish"
command = "echo publish"
depends_on = ["checks"]
condition = { expression = '(env.PUBLISH ?? "1") == "1"' }
EOF
printf '/.goodflows/\n' >.gitignore
git add -A
git -c user.name=smoke -c user.email=smoke@example.com commit -qm smoke

# run NAME COMMAND...: runs a goodflows command, keeps its output, and records
# the run ids it added under .goodflows/reports as $NAME (root run) and
# ${NAME}_child (called workflow).
run() {
  local name=$1 before
  shift
  before=$(ls .goodflows/reports 2>/dev/null || true)
  "$@" >"$work/$name.out" 2>&1 || echo "  $name: goodflows exited $? (see $work/$name.out)"
  grep 'run history for' "$work/$name.out" | sed "s/^/  $name: /" || true
  for id in $(ls .goodflows/reports); do
    grep -qx "$id" <<<"$before" && continue
    if [[ $(jq -r '.parent_run_id // empty' ".goodflows/reports/$id/run-record.json") ]]; then
      printf -v "${name}_child" %s "$id"
    else
      printf -v "$name" %s "$id"
    fi
  done
}
gha() { # GitHub Actions variables for one run: gha EVENT RUN_ID REF
  env GITHUB_ACTIONS=true GITHUB_EVENT_NAME="$1" GITHUB_RUN_ID="$2" GITHUB_RUN_ATTEMPT=1 \
    GITHUB_REF="$3" RUNNER_NAME=smoke-runner GITHUB_SERVER_URL=https://github.com \
    GITHUB_REPOSITORY=agoodway/goodflows_web "${@:4}"
}

run release "$goodflows" run release # parent `release` calls `default` (child)
git checkout -q --detach # GitHub pull_request checkouts are detached: no branch
run pr gha pull_request 1001 refs/pull/16/merge "$goodflows" run
git checkout -q "$branch"
run push gha push 1002 "refs/heads/$branch" "$goodflows" run

say "Spool replay: server stopped, run, server restarted, reports upload"
stop_server
run spooled gha schedule 1003 "refs/heads/$branch" "$goodflows" run
spool=".goodflows/reports/$spooled"
spool_pending() { grep -q 'upload pending' "$work/spooled.out" && [[ ! -e $spool/run-record.ack.json ]]; }
check "upload spooled while the server is down" spool_pending
start_server
"$goodflows" reports upload "$spool" >"$work/replay.out" 2>&1 || true
sed 's/^/  /' "$work/replay.out"
replayed() { grep -q 'Run history: acknowledged' "$work/replay.out" && [[ -e $spool/run-record.ack.json ]]; }
check "spooled record replays: Run history acknowledged" replayed

say "Server-side checks"
uploads() { [[ $(grep -c 'upload.*uploaded$\|history for .* uploaded$' "$work/$1.out") == "$2" ]]; }
check "CLI uploaded release and its called default run" uploads release 2
check "CLI uploaded pull_request run" uploads pr 1
check "CLI uploaded push run" uploads push 1
# Each CLI upload is a POST /workflow-runs; Phoenix logs its status next.
statuses=$(awk '/POST \/api\/v1\/projects\/[^ ]*\/workflow-runs/ {p=1; next} p && /Sent [0-9]+/ {print $3; p=0}' "$server_log" | sort | uniq -c | xargs)
echo "  POST workflow-runs statuses (count status): $statuses"
check "every upload returned 201 (5 records, no 422)" test "$statuses" = "5 201"

for name in release release_child pr push spooled; do
  curl -fsS "${auth[@]}" "$runs_url/${!name}" | jq '.data.document' >"$work/$name.json"
done
doc() { jq -e --arg b "$branch" --arg parent "$release" "$2" "$work/$1.json" >/dev/null; }
check "parent stored with graph (call to default) and source.branch" \
  doc release '(.graph.jobs | any(.call.workflow == "default")) and .source.branch == $b'
check "child stored with parent link, graph and source.branch" \
  doc release_child '.parent_run_id == $parent and .caller_job == "checks" and (.graph.jobs | length) == 2 and .source.branch == $b'
check "pull_request run stored with ci and graph, no branch" \
  doc pr '.ci.provider == "github_actions" and .ci.event == "pull_request" and .ci.pull_request == 16 and .source.branch == null and .graph != null'
check "push run stored with ci, graph and source.branch" \
  doc push '.ci.event == "push" and .source.branch == $b and .graph != null'
check "spooled run stored with ci, graph and source.branch" \
  doc spooled '.ci.event == "schedule" and .source.branch == $b and .graph != null'

code=$(curl -sS "${auth[@]}" -H 'content-type: application/json' -o "$work/retry.json" -w '%{http_code}' \
  --data-binary "@.goodflows/reports/$release/run-record.json" "$runs_url")
echo "  exact retry of $release: HTTP $code $(cat "$work/retry.json")"
retry_ok() {
  [[ $code == 200 ]] && jq -e --slurpfile ack ".goodflows/reports/$release/run-record.ack.json" \
    '.data.duplicate == true and .data.id == $ack[0].id' "$work/retry.json" >/dev/null
}
check "exact retry returns 200 with the stored id and duplicate true" retry_ok

ids() { sort | xargs; }
expect() { printf '%s\n' "$@" | ids; }
api_list() { curl -fsS "${auth[@]}" "$runs_url?$1" | jq -r '.data[].run_id' | ids; }
cli_list() { "$goodflows" history list --json "$@" | jq -r '.runs[].run_id' | ids; }
on_branch=$(expect "$release" "$release_child" "$push" "$spooled")
for filter in "branch=$branch|$on_branch" "event=pull_request|$pr" "event=push|$push" \
  "branch=$branch&event=schedule|$spooled" "branch=nope|"; do
  query=${filter%%|*} want=${filter#*|}
  got=$(api_list "$query")
  echo "  GET workflow-runs?$query -> [$got]"
  check "GET workflow-runs?$query" test "$got" = "$(expect $want)"
done
for args in "--branch $branch|$on_branch" "--event pull_request|$pr" \
  "--branch $branch --event push|$push"; do
  want=${args#*|}
  read -ra flags <<<"${args%%|*}"
  got=$(cli_list "${flags[@]}")
  echo "  goodflows history list ${flags[*]} -> [$got]"
  check "goodflows history list ${flags[*]}" test "$got" = "$(expect $want)"
done
"$goodflows" history list --branch "$branch" | sed 's/^/  /'

say "Result"
echo "project $project, workspace $work, server log $server_log"
if ((failures)); then
  echo "FAILED: $failures check(s)"
  exit 1
fi
echo "ALL CHECKS PASSED"
