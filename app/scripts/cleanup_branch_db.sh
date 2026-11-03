#!/usr/bin/env bash
# Require a saved branch id so cleanup cannot drop the main checkout’s databases.
set -euo pipefail

cd "$(dirname "$0")/.."

source scripts/branch_db_env.sh
branch_id=$(read_branch_db)
if [ -z "$branch_id" ]; then
  echo "No saved BRANCH_DB; skipping database cleanup"
  exit 0
fi

export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGHOST="${PGHOST:-localhost}"

for db in "good_flows_${branch_id}_dev" "good_flows_${branch_id}_test"; do
  echo "Dropping $db"
  dropdb --if-exists --force "$db"
done
