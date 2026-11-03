#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGHOST="${PGHOST:-localhost}"

source scripts/branch_db_env.sh
branch_id=$(read_branch_db)
if [ -z "$branch_id" ]; then
  branch=$(git branch --show-current)
  case "$branch" in
    "") echo "Error: detached HEAD; check out a branch first" >&2; exit 1 ;;
    main | master) echo "Error: the main checkout uses the default databases" >&2; exit 1 ;;
  esac
  branch=${branch#*/}
  branch=${branch//[^a-zA-Z0-9]/_}
  branch_id=${branch:0:24}
fi

set_env_default .env.dev.local BRANCH_DB "$branch_id"
set_env_default .env.test.local BRANCH_DB "$branch_id"
# Re-read saved ids so setup and cleanup always target the same databases.
branch_id=$(read_branch_db)
export BRANCH_DB="$branch_id"
dev_db="good_flows_${branch_id}_dev"
test_db="good_flows_${branch_id}_test"

# Preserve customized ports because generated ports can collide.
port=$((4100 + $(printf '%s' "$branch_id" | cksum | cut -d' ' -f1) % 200))
set_env_default .env.dev.local PORT "$port"

db_exists() {
  [ "$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$1'")" = "1" ]
}

echo "Setting up databases for branch: $branch_id"

# Manual runs may not have fetched dependencies through workie hooks.
[ -d deps ] || mix deps.get

if db_exists "$dev_db"; then
  echo "$dev_db already exists"
elif createdb -T good_flows_dev "$dev_db"; then
  echo "Created $dev_db as a copy of good_flows_dev"
else
  echo "Could not copy good_flows_dev; creating $dev_db empty and seeding it"
  # Persist seed intent before creation so interrupted initialization can be retried.
  set_env_default .env.dev.local BRANCH_DB_SEED_PENDING "$branch_id"
  createdb "$dev_db"
fi

MIX_ENV=dev mix ecto.migrate
if grep -Fxq "BRANCH_DB_SEED_PENDING=$branch_id" .env.dev.local; then
  MIX_ENV=dev mix run priv/repo/seeds.exs
  sed -i "/^BRANCH_DB_SEED_PENDING=$branch_id$/d" .env.dev.local
fi

if db_exists "$test_db"; then
  echo "$test_db already exists"
else
  createdb "$test_db"
fi
env -u TEST_DATABASE_PREFIX -u MIX_TEST_PARTITION MIX_ENV=test mix ecto.migrate

echo "Databases ready: $dev_db, $test_db"
