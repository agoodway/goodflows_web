#!/usr/bin/env bash
# Start an isolated GoodFlows Web dev server for one verification run.
#
#   launch.sh [run-id]
#
# The server gets a free port and its own database (BRANCH_DB=verify_<hash>,
# so good_flows_verify_<hash>_dev), created, migrated and seeded from empty.
# GOOD_FLOWS_* variables in the caller's environment reach the server, e.g.
#   GOOD_FLOWS_USER_REGISTRATION_ENABLED=false launch.sh
# Prints RUN_ID, RUN_DIR and BASE_URL lines on success. Stop it with cleanup.sh.
set -euo pipefail

skill=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo=$(git -C "$skill" rev-parse --show-toplevel)
app="$repo/app"

sha=$(git -C "$repo" rev-parse HEAD)
run_id=${1:-$(date -u +%Y%m%dT%H%M%SZ)-${sha:0:7}}
if [[ ! $run_id =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "run id may only contain letters, digits, '.', '_' and '-'" >&2
  exit 2
fi
run_dir="$repo/.verify/goodflows-web/$run_id"
inst="$run_dir/.instance"

if [[ -f $inst/pid ]] && kill -0 "$(cat "$inst/pid")" 2>/dev/null; then
  echo "run $run_id already has a live server (pid $(cat "$inst/pid")); use doctor.sh or cleanup.sh" >&2
  exit 1
fi
mkdir -p "$inst"

port=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
branch_db="verify_$(printf '%s' "$run_id" | sha1sum | cut -c1-10)"
base_url="http://localhost:$port"
dirty=clean
[[ -n $(git -C "$repo" status --porcelain) ]] && dirty=dirty

printf '%s\n' "$port" >"$inst/port"
printf '%s\n' "$branch_db" >"$inst/branch_db"
printf '%s\n' "$base_url" >"$inst/base_url"
{
  echo "sha=$sha"
  echo "branch=$(git -C "$repo" branch --show-current)"
  echo "tree=$dirty"
  echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  env | grep '^GOOD_FLOWS_' || true
} >"$inst/build"

export MIX_ENV=dev BRANCH_DB="$branch_db" PORT="$port" PHX_HOST=localhost
cd "$app"

echo "== database good_flows_${branch_db}_dev (log: $run_dir/setup.log)"
if ! mix ecto.setup >"$run_dir/setup.log" 2>&1; then
  tail -30 "$run_dir/setup.log" >&2
  exit 1
fi
if [[ ! -f priv/static/assets/js/app.js || ! -f priv/static/assets/css/app.css ]]; then
  echo "== building assets"
  mix do assets.setup, assets.build >>"$run_dir/setup.log" 2>&1
fi

echo "== server on $base_url (log: $run_dir/server.log)"
# setsid makes the server a process group leader, so cleanup.sh can stop
# it and its esbuild/tailwind watchers without touching anything else.
(exec setsid mix phx.server >>"$run_dir/server.log" 2>&1) &
pid=$!
printf '%s\n' "$pid" >"$inst/pid"

for _ in $(seq 180); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "server exited during startup; last log lines:" >&2
    tail -30 "$run_dir/server.log" >&2
    exit 1
  fi
  if curl -fsS "$base_url/users/log-in" 2>/dev/null | grep -q 'id="login_form_password"'; then
    echo "RUN_ID=$run_id"
    echo "RUN_DIR=$run_dir"
    echo "BASE_URL=$base_url"
    exit 0
  fi
  sleep 1
done
echo "server not ready after 180s; see $run_dir/server.log" >&2
exit 1
