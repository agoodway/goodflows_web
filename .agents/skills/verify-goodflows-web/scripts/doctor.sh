#!/usr/bin/env bash
# Read-only check that a verification run's server is worth driving.
#
#   doctor.sh <run-id>
#
# Prints PASS/WARN/FAIL per check and exits 1 on any FAIL.
set -uo pipefail

skill=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo=$(git -C "$skill" rev-parse --show-toplevel)
run_id=${1:?usage: doctor.sh <run-id>}
inst="$repo/.verify/goodflows-web/$run_id/.instance"
fails=0

pass() { echo "PASS  $*"; }
warn() { echo "WARN  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }

if [[ ! -f $inst/pid ]]; then
  echo "FAIL  no instance for run $run_id (expected $inst/pid); run launch.sh"
  exit 1
fi
pid=$(cat "$inst/pid")
port=$(cat "$inst/port")
base_url=$(cat "$inst/base_url")
branch_db=$(cat "$inst/branch_db")

if kill -0 "$pid" 2>/dev/null; then pass "server process group $pid is alive"; else fail "server pid $pid is not running"; fi

listener=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
if [[ -n $listener ]] && [[ $(ps -o pgid= -p "$listener" | tr -d ' ') == "$pid" ]]; then
  pass "port $port is held by this run's server (pid $listener)"
else
  fail "port $port is not held by process group $pid (listener: ${listener:-none})"
fi

if curl -fsS "$base_url/users/log-in" 2>/dev/null | grep -q 'id="login_form_password"'; then
  pass "$base_url/users/log-in renders the login form"
else
  fail "$base_url/users/log-in does not render the login form"
fi

db="good_flows_${branch_db}_dev"
seeded=$(PGPASSWORD=postgres psql -h localhost -U postgres -d "$db" -tAc \
  "select count(*) from users where email = 'user@example.com'" 2>/dev/null)
if [[ $seeded == 1 ]]; then pass "database $db has the seeded user"; else fail "database $db is missing or unseeded"; fi

launched_sha=$(sed -n 's/^sha=//p' "$inst/build")
launched_tree=$(sed -n 's/^tree=//p' "$inst/build")
head_sha=$(git -C "$repo" rev-parse HEAD)
tree=clean
[[ -n $(git -C "$repo" status --porcelain -- . ':!.verify') ]] && tree=dirty
# The dev code reloader recompiles from disk on each request, so the app
# serves whatever the checkout holds now, not only the launch commit.
if [[ $launched_sha == "$head_sha" && $tree == clean ]]; then
  pass "checkout is clean at $head_sha (launched at $launched_sha, $launched_tree)"
elif [[ $launched_sha != "$head_sha" ]]; then
  warn "HEAD moved from $launched_sha to $head_sha since launch; the app serves the new code"
else
  warn "working tree is dirty at $head_sha; the app serves uncommitted code"
fi

sed -n 's/^GOOD_FLOWS_/env GOOD_FLOWS_/p' "$inst/build"
exit $((fails > 0))
