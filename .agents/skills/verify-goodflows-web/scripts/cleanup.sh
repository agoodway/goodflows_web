#!/usr/bin/env bash
# Stop one run's server and drop its database. Evidence stays.
#
#   cleanup.sh <run-id>
#
# Kills only the process group launch.sh started and drops only that run's
# good_flows_verify_*_dev database, then removes the run's .instance/ state.
# Screenshots, logs and run.md under .verify/goodflows-web/<run-id>/ remain.
set -uo pipefail

skill=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo=$(git -C "$skill" rev-parse --show-toplevel)
run_id=${1:?usage: cleanup.sh <run-id>}
run_dir="$repo/.verify/goodflows-web/$run_id"
inst="$run_dir/.instance"

if [[ ! -d $inst ]]; then
  echo "no instance state for $run_id; nothing to stop"
  exit 0
fi

if [[ -f $inst/pid ]]; then
  pid=$(cat "$inst/pid")
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    for _ in $(seq 15); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && kill -KILL -- "-$pid" 2>/dev/null
    echo "stopped process group $pid"
  fi
fi

if [[ -f $inst/branch_db ]]; then
  branch_db=$(cat "$inst/branch_db")
  if [[ $branch_db =~ ^verify_[0-9a-f]{10}$ ]]; then
    (cd "$repo/app" && MIX_ENV=dev BRANCH_DB="$branch_db" mix ecto.drop --force-drop >>"$run_dir/setup.log" 2>&1) &&
      echo "dropped database good_flows_${branch_db}_dev"
  else
    echo "refusing to drop unexpected database name '$branch_db'" >&2
  fi
fi

rm -rf "$inst"
echo "evidence kept in $run_dir:"
ls -A "$run_dir"
